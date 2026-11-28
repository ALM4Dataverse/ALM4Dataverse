# Shared library: dot-sourced by setup-common.ps1 and embedded into release installers.
# The browser assets are embedded so released setup installers remain a single file.
function Get-SetupWebUiAsset {
    <#
    .SYNOPSIS
        Returns one of the embedded setup web UI assets as text.
    .PARAMETER Name
        Embedded asset name. Logo bytes have a separate helper because they are binary.
    .OUTPUTS
        System.String. UTF-8 text for the requested asset.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('index.html', 'app.css', 'app.js')][string]$Name
    )

    switch ($Name) {
        'index.html' { return $script:SetupWebUiHtml }
        'app.css' { return $script:SetupWebUiCss }
        'app.js' { return $script:SetupWebUiJavaScript }
    }
}

function Get-SetupWebLogo {
    <#
    .SYNOPSIS
        Decodes the embedded product logo.
    .DESCRIPTION
        The constant is a copy of the repository logo.png kept for standalone installers.
        Tests compare the decoded bytes with logo.png so the two cannot drift silently.
    .OUTPUTS
        System.Byte[]. PNG image content.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'The unary comma preserves one byte array object; the declared element type is intentional.')]
    [CmdletBinding()]
    [OutputType([byte[]])]
    param()

    return ,([Convert]::FromBase64String(($script:SetupWebLogoBase64 -replace '\s', '')))
}

$script:SetupWebUiHtml = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="light" />
  <title>ALM4Dataverse Setup</title>
  <link rel="icon" href="logo.png" />
  <link rel="stylesheet" href="app.css" />
</head>
<body>
  <svg xmlns="http://www.w3.org/2000/svg" style="display:none" aria-hidden="true">
    <symbol id="icon-check" viewBox="0 0 20 20">
      <path d="M7.03 13.9 3.1 9.97l1.06-1.06 2.87 2.87 7.8-7.8 1.06 1.06z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-dismiss" viewBox="0 0 20 20">
      <path d="M4.47 4.47 10 10l5.53-5.53 1.06 1.06L11.06 11l5.53 5.53-1.06 1.06L10 12.06l-5.53 5.53-1.06-1.06L8.94 11 3.41 5.53z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-info" viewBox="0 0 20 20">
      <path d="M10 2a8 8 0 1 0 0 16 8 8 0 0 0 0-16zm.75 11.5h-1.5v-5h1.5zm-.75-6.75a1 1 0 1 1 0-2 1 1 0 0 1 0 2z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-sun" viewBox="0 0 20 20">
      <path d="M10 6.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zm0 1.5a2 2 0 1 1 0 4 2 2 0 0 1 0-4zM9.25 1.5h1.5v2h-1.5zm0 15h1.5v2h-1.5zM1.5 9.25h2v1.5h-2zm15 0h2v1.5h-2zM3.58 4.64l1.06-1.06 1.42 1.42-1.06 1.06zm10.36 10.36 1.06-1.06 1.42 1.42-1.06 1.06zM4.64 16.42l-1.06-1.06 1.42-1.42 1.06 1.06zM15 6.06l-1.06-1.06 1.42-1.42 1.06 1.06z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-moon" viewBox="0 0 20 20">
      <path d="M10.1 2.3a7.8 7.8 0 1 0 7.6 7.8 6.4 6.4 0 0 1-7.6-7.8z" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"/>
    </symbol>
    <symbol id="icon-repo" viewBox="0 0 20 20">
      <path d="M5 2.5h10a1.5 1.5 0 0 1 1.5 1.5v12A1.5 1.5 0 0 1 15 17.5H5A1.5 1.5 0 0 1 3.5 16V4A1.5 1.5 0 0 1 5 2.5zm0 1.5a.5.5 0 0 0-.5.5v11c0 .28.22.5.5.5h10a.5.5 0 0 0 .5-.5V4a.5.5 0 0 0-.5-.5zm2 2h6V7.5H7zm0 3h6v1.5H7z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-search" viewBox="0 0 20 20">
      <path d="M8.5 3a5.5 5.5 0 0 1 4.33 8.88l3.4 3.4-1.06 1.06-3.4-3.4A5.5 5.5 0 1 1 8.5 3zm0 1.5a4 4 0 1 0 0 8 4 4 0 0 0 0-8z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-activity" viewBox="0 0 20 20">
      <path d="M3 4.5h14v1.5H3zm0 4.75h14v1.5H3zm0 4.75h14v1.5H3z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-warning" viewBox="0 0 20 20">
      <path d="M10 2.5a1.5 1.5 0 0 1 1.3.75l7 12.25A1.5 1.5 0 0 1 17 17.75H3a1.5 1.5 0 0 1-1.3-2.25l7-12.25A1.5 1.5 0 0 1 10 2.5zm0 3L4.1 15.75h11.8zM10 8a.75.75 0 0 1 .75.75v3.5a.75.75 0 0 1-1.5 0v-3.5A.75.75 0 0 1 10 8zm0 6a1 1 0 1 1 0 2 1 1 0 0 1 0-2z" fill="currentColor"/>
    </symbol>
    <symbol id="icon-branch" viewBox="0 0 20 20">
      <path d="M6.5 3a1.75 1.75 0 1 1 0 3.5 1.75 1.75 0 0 1 0-3.5zm7 0a1.75 1.75 0 1 1 0 3.5 1.75 1.75 0 0 1 0-3.5zM6.5 13.5a1.75 1.75 0 1 1 0 3.5 1.75 1.75 0 0 1 0-3.5z" fill="none" stroke="currentColor" stroke-width="1.5"/>
      <path d="M6.5 6.5v7M13.5 6.5v1A3.5 3.5 0 0 1 10 11H6.5" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>
    </symbol>
    <symbol id="icon-chevron" viewBox="0 0 20 20">
      <path d="M7.5 4.5 13 10l-5.5 5.5-1.06-1.06L10.88 10 6.44 5.56z" fill="currentColor"/>
    </symbol>
  </svg>

  <div class="shell">
    <header class="shell-header">
      <div class="brand">
        <img class="brand-logo" src="logo.png" alt="ALM4Dataverse" />
      </div>
      <a id="repository-chip" class="repo-chip" hidden target="_blank" rel="noreferrer noopener">
        <svg class="icon" aria-hidden="true"><use href="#icon-repo"></use></svg>
        <span id="repository-name" class="repo-name"></span>
      </a>
      <div class="header-meta">
        <span id="provider-pill" class="pill pill-provider">Setup</span>
        <span id="version-pill" class="pill pill-version">Development</span>
        <button id="theme-toggle" class="icon-button theme-toggle" type="button" aria-label="Switch to dark theme" title="Switch to dark theme">
          <svg class="icon" aria-hidden="true"><use href="#icon-moon"></use></svg>
        </button>
      </div>
    </header>

    <div id="device-banner" class="device-banner" role="dialog" aria-modal="true" aria-labelledby="device-title" hidden>
      <div class="device-mark" aria-hidden="true"><svg class="icon" aria-hidden="true"><use href="#icon-warning"></use></svg></div>
      <div class="device-copy">
        <p id="device-title" class="eyebrow">Sign-in required</p>
        <pre id="device-message" class="device-message"></pre>
        <div class="device-actions">
          <a id="device-link" class="btn btn-secondary" href="#" target="_blank" rel="noreferrer noopener" hidden>Open sign-in page</a>
          <button id="device-copy" class="btn btn-ghost" type="button">Copy code</button>
        </div>
      </div>
    </div>

    <main id="stage" class="stage" aria-live="polite">
      <section class="card hero-card">
        <p class="eyebrow">ALM4Dataverse</p>
        <h1>Preparing your setup workspace</h1>
        <p class="lede">The setup window is starting. This page will update automatically.</p>
        <div class="thinking"><span class="spinner" aria-hidden="true"></span><span>Connecting to setup...</span></div>
      </section>
    </main>

    <footer class="shell-footer">
      <span>ALM4Dataverse automated setup</span>
      <div class="footer-status">
        <span id="connection" class="connection is-online"><span class="connection-dot"></span><span id="connection-text">Connected</span></span>
        <button id="activity-fab" class="activity-fab" type="button" aria-controls="activity-drawer" aria-expanded="false">
          <svg class="icon" aria-hidden="true"><use href="#icon-activity"></use></svg>
          <span>Activity</span>
          <span id="activity-count" class="activity-count">0</span>
        </button>
      </div>
    </footer>
  </div>

  <div id="busy-indicator" class="busy-indicator" role="status" aria-live="polite" hidden>
    <svg class="busy-spinner" viewBox="0 0 48 48" aria-hidden="true">
      <circle class="busy-spinner-track" cx="24" cy="24" r="19"></circle>
      <circle class="busy-spinner-arc" cx="24" cy="24" r="19"></circle>
    </svg>
    <span id="busy-message">Working on the next step...</span>
  </div>

  <aside id="activity-drawer" class="activity-drawer" aria-label="Setup activity">
    <header class="activity-head">
      <div>
        <p class="eyebrow">Live log</p>
        <h2>Setup activity</h2>
      </div>
      <button id="activity-close" class="icon-button" type="button" aria-label="Close activity">Close</button>
    </header>
    <div id="activity-log" class="activity-log" role="log" aria-live="polite"></div>
  </aside>

  <div id="toast" class="toast" hidden role="status"></div>

  <script src="app.js"></script>
</body>
</html>

'@

$script:SetupWebUiCss = @'
/* Fluent 2 design tokens and component patterns. Styles are embedded locally so
   released installers stay offline and single-file. Light is the default theme;
   the header toggle switches the browser page to dark mode. */

:root {
  color-scheme: light;

  --font-family-base: "Segoe UI Variable Text", "Segoe UI", -apple-system, "Helvetica Neue", Arial, sans-serif;
  --font-family-monospace: "Cascadia Code", "Segoe UI Mono", "SFMono-Regular", Consolas, "Liberation Mono", monospace;

  --neutral-background-1: #ffffff;
  --neutral-background-2: #faf9f8;
  --neutral-background-3: #f3f2f1;
  --neutral-background-4: #f0f0f0;
  --neutral-background-5: #e5e5e5;
  --neutral-background-disabled: #f0f0f0;
  --busy-scrim: rgba(250, 249, 248, 0.65);
  --neutral-foreground-1: #242424;
  --neutral-foreground-2: #424242;
  --neutral-foreground-3: #616161;
  --neutral-foreground-disabled: #bdbdbd;
  --neutral-stroke-1: #d1d1d1;
  --neutral-stroke-2: #e0e0e0;
  --neutral-stroke-3: #f0f0f0;
  --neutral-stroke-accessible: #616161;

  --brand-background: #0f6cbd;
  --brand-background-hover: #115ea3;
  --brand-background-pressed: #0f548c;
  --brand-background-2: #e6f2fb;
  --brand-background-3: #cfe8fa;
  --brand-foreground-1: #0f6cbd;
  --brand-foreground-2: #115ea3;
  --brand-stroke-1: #0f6cbd;
  --neutral-foreground-on-brand: #ffffff;
  --brand-logo-plate: transparent;

  --success-background: #f1faf1;
  --success-background-hover: #dff6dd;
  --success-foreground: #107c10;
  --success-border: #9fd89f;
  --warning-background: #fff9f5;
  --warning-foreground: #bc4b09;
  --warning-border: #fdcfb4;
  --danger-background: #fdf3f4;
  --danger-background-hover: #fbe8ea;
  --danger-foreground: #c50f1f;
  --danger-border: #eeacb2;
  --info-background: #f5fafd;
  --info-border: #b4d6fa;
  --info-foreground: #0f6cbd;

  --shadow-2: 0 1px 2px rgba(0, 0, 0, 0.14), 0 0 2px rgba(0, 0, 0, 0.12);
  --shadow-4: 0 2px 4px rgba(0, 0, 0, 0.14), 0 0 2px rgba(0, 0, 0, 0.12);
  --shadow-8: 0 4px 8px rgba(0, 0, 0, 0.14), 0 0 2px rgba(0, 0, 0, 0.12);
  --shadow-16: 0 8px 16px rgba(0, 0, 0, 0.14), 0 0 2px rgba(0, 0, 0, 0.12);
  --shadow-64: 0 32px 64px rgba(0, 0, 0, 0.24), 0 0 8px rgba(0, 0, 0, 0.2);

  --radius-small: 2px;
  --radius-medium: 4px;
  --radius-large: 6px;
  --radius-xlarge: 8px;
  --radius-circular: 10000px;

  --duration-fast: 100ms;
  --curve-easy-ease: cubic-bezier(0.33, 0, 0.67, 1);
}

:root[data-theme="dark"] {
  color-scheme: dark;
  --neutral-background-1: #292929;
    --neutral-background-2: #1f1f1f;
    --neutral-background-3: #141414;
    --neutral-background-4: #0f0f0f;
    --neutral-background-5: #333333;
    --neutral-background-disabled: #141414;
    --busy-scrim: rgba(15, 15, 15, 0.68);
    --neutral-foreground-1: #ffffff;
    --neutral-foreground-2: #d6d6d6;
    --neutral-foreground-3: #adadad;
    --neutral-foreground-disabled: #5c5c5c;
    --neutral-stroke-1: #666666;
    --neutral-stroke-2: #525252;
    --neutral-stroke-3: #3d3d3d;
    --neutral-stroke-accessible: #adadad;

    --brand-background: #479ef5;
    --brand-background-hover: #62abf5;
    --brand-background-pressed: #2886de;
    --brand-background-2: #082338;
    --brand-background-3: #0c3b5e;
    --brand-foreground-1: #479ef5;
    --brand-foreground-2: #62abf5;
    --brand-stroke-1: #479ef5;
    --neutral-foreground-on-brand: #000000;
    --brand-logo-plate: #ffffff;

    --success-background: #052505;
    --success-background-hover: #0e3a0e;
    --success-foreground: #6ccb5f;
    --success-border: #2c682c;
    --warning-background: #291a05;
    --warning-foreground: #fce100;
    --warning-border: #6d4b0f;
    --danger-background: #3f1011;
    --danger-background-hover: #4d1516;
    --danger-foreground: #dc626d;
    --danger-border: #8a2b33;
    --info-background: #082338;
    --info-border: #0c3b5e;
    --info-foreground: #62abf5;

    --shadow-2: 0 1px 2px rgba(0, 0, 0, 0.4), 0 0 2px rgba(0, 0, 0, 0.3);
    --shadow-4: 0 2px 4px rgba(0, 0, 0, 0.4), 0 0 2px rgba(0, 0, 0, 0.3);
    --shadow-8: 0 4px 8px rgba(0, 0, 0, 0.4), 0 0 2px rgba(0, 0, 0, 0.3);
    --shadow-16: 0 8px 16px rgba(0, 0, 0, 0.4), 0 0 2px rgba(0, 0, 0, 0.3);
  --shadow-64: 0 32px 64px rgba(0, 0, 0, 0.55), 0 0 8px rgba(0, 0, 0, 0.4);
}

* {
  box-sizing: border-box;
}

[hidden] {
  display: none !important;
}

html {
  min-height: 100%;
}

body {
  margin: 0;
  min-height: 100vh;
  background: var(--neutral-background-2);
  color: var(--neutral-foreground-1);
  font-family: var(--font-family-base);
  font-size: 14px;
  line-height: 1.45;
  -webkit-font-smoothing: antialiased;
}

.shell {
  width: min(1120px, 100%);
  margin: 0 auto;
  padding: 20px clamp(16px, 3vw, 32px) 32px;
}

.shell-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
  padding: 4px 0 16px;
  border-bottom: 1px solid var(--neutral-stroke-2);
}

.brand {
  display: flex;
  align-items: center;
  gap: 12px;
}

.brand-logo {
  display: block;
  height: 48px;
  width: auto;
  padding: 0;
  background: var(--brand-logo-plate);
  border-radius: var(--radius-medium);
}

:root[data-theme="dark"] .brand-logo {
  height: 44px;
  padding: 5px 10px;
}

.repo-chip {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  max-width: 420px;
  height: 28px;
  padding: 0 8px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-medium);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  font-size: 12px;
  font-weight: 600;
  text-decoration: none;
  overflow: hidden;
}

.repo-chip .icon {
  flex: none;
  width: 16px;
  height: 16px;
  color: var(--neutral-foreground-3);
}

.repo-chip .repo-name {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.repo-chip:hover {
  background: var(--neutral-background-3);
  border-color: var(--neutral-stroke-1);
}

.repo-chip:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.header-meta {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
}

.pill {
  display: inline-flex;
  align-items: center;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-small);
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
}

.pill-provider {
  background: var(--brand-background-2);
  color: var(--brand-foreground-1);
}

.connection {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  font-weight: 600;
}

.connection-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--warning-foreground);
}

.connection.is-online .connection-dot {
  background: var(--success-foreground);
}

.connection.is-offline {
  color: var(--danger-foreground);
}

.connection.is-offline .connection-dot {
  background: var(--danger-foreground);
}

.stage {
  padding-top: 24px;
}

.stage-inner {
  display: grid;
  gap: 16px;
}

.card {
  background: var(--neutral-background-1);
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-xlarge);
  box-shadow: var(--shadow-2);
  padding: 24px;
}

.card > *:first-child {
  margin-top: 0;
}

.eyebrow {
  margin: 0 0 6px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  font-weight: 600;
  letter-spacing: 0;
  text-transform: none;
}

h1,
h2,
h3 {
  margin: 0;
  color: var(--neutral-foreground-1);
  font-weight: 600;
  line-height: 1.2;
}

h1 {
  font-size: clamp(22px, 2.6vw, 28px);
}

h2 {
  font-size: 20px;
}

h3 {
  font-size: 16px;
}

.lede {
  margin: 8px 0 0;
  max-width: 72ch;
  color: var(--neutral-foreground-2);
  font-size: 14px;
  line-height: 1.5;
}

.guidance {
  display: grid;
  gap: 4px;
  margin: 16px 0 0;
  padding: 10px 12px;
  list-style: none;
  background: var(--info-background);
  border: 1px solid var(--info-border);
  border-radius: var(--radius-medium);
}

.guidance li {
  position: relative;
  padding-left: 18px;
  color: var(--neutral-foreground-2);
  font-size: 13px;
  line-height: 1.45;
}

.guidance li::before {
  content: "";
  position: absolute;
  left: 4px;
  top: 6px;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--info-foreground);
}

.help-link {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  margin-top: 12px;
  padding: 4px 0;
  color: var(--brand-foreground-1);
  font-size: 13px;
  font-weight: 600;
  text-decoration: none;
  border-radius: var(--radius-medium);
}

.help-link:hover {
  color: var(--brand-foreground-2);
  text-decoration: underline;
}

.help-link:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 2px;
}

.thinking {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  margin-top: 16px;
  color: var(--neutral-foreground-2);
  font-size: 13px;
}

.spinner {
  width: 20px;
  height: 20px;
  border-radius: 50%;
  border: 2px solid var(--neutral-stroke-2);
  border-top-color: var(--brand-foreground-1);
  animation: spin 0.9s linear infinite;
  flex: none;
}

@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

/* Fluent Badge / InfoBar / Card patterns */

.prompt-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}

.prompt-kind {
  flex: none;
  display: inline-flex;
  align-items: center;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-small);
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
}

.notice {
  display: flex;
  align-items: flex-start;
  gap: 8px;
  margin-top: 16px;
  padding: 10px 12px;
  border: 1px solid var(--info-border);
  border-radius: var(--radius-medium);
  background: var(--info-background);
  color: var(--neutral-foreground-2);
  font-size: 13px;
  line-height: 1.45;
}

.notice::before {
  content: "i";
  flex: none;
  display: grid;
  place-items: center;
  width: 16px;
  height: 16px;
  margin-top: 1px;
  border-radius: 50%;
  background: var(--info-foreground);
  color: var(--neutral-background-1);
  font-family: "Segoe UI", sans-serif;
  font-size: 11px;
  font-weight: 700;
}

.notice.is-error {
  border-color: var(--danger-border);
  background: var(--danger-background);
  color: var(--neutral-foreground-1);
}

.notice.is-error::before {
  content: "!";
  background: var(--danger-foreground);
  color: var(--neutral-background-1);
}

/* Fluent Radio list for menus */

.choice-list {
  display: grid;
  gap: 6px;
  margin-top: 16px;
}

.choice {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  min-height: 40px;
  padding: 8px 12px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-medium);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  font: inherit;
  font-size: 14px;
  font-weight: 400;
  text-align: left;
  cursor: pointer;
  transition: background var(--duration-fast) var(--curve-easy-ease),
    border-color var(--duration-fast) var(--curve-easy-ease);
}

.choice:hover {
  background: var(--neutral-background-2);
  border-color: var(--neutral-stroke-1);
}

.choice:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.choice-marker {
  flex: none;
  width: 16px;
  height: 16px;
  border: 1px solid var(--neutral-stroke-accessible);
  border-radius: 50%;
  background: var(--neutral-background-1);
  position: relative;
}

.choice.is-selected .choice-marker {
  border-color: var(--brand-stroke-1);
  border-width: 5px;
}

.choice-text {
  flex: 1;
  min-width: 0;
}

.choice-hint {
  display: block;
  margin-top: 2px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
}

.choice.is-action {
  border-color: var(--neutral-stroke-1);
  background: var(--neutral-background-2);
}

.choice.is-action .choice-marker {
  border-color: var(--brand-stroke-1);
  background: var(--brand-background-2);
}

.choice.is-action::after {
  content: "\203A";
  color: var(--neutral-foreground-3);
  font-size: 18px;
  line-height: 1;
  padding-left: 4px;
}

.choice.is-dimmed {
  color: var(--neutral-foreground-disabled);
  background: var(--neutral-background-disabled);
  cursor: not-allowed;
}

.choice-separator {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 8px 0 0;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  font-weight: 600;
}

.choice-separator::after {
  content: "";
  flex: 1;
  height: 1px;
  background: var(--neutral-stroke-2);
}

/* Fluent Card step board */

.wizard-head {
  display: flex;
  justify-content: space-between;
  align-items: flex-end;
  gap: 20px;
  flex-wrap: wrap;
}

.wizard-progress {
  min-width: 180px;
  flex: 1;
  max-width: 300px;
}

.wizard-progress-label {
  display: flex;
  justify-content: space-between;
  gap: 12px;
  margin-bottom: 6px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  font-weight: 600;
}

.progress-track {
  height: 2px;
  border-radius: 1px;
  background: var(--neutral-background-4);
  overflow: hidden;
}

.progress-fill {
  height: 100%;
  border-radius: 1px;
  background: var(--brand-background);
  transition: width var(--duration-fast) var(--curve-easy-ease);
}

.step-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 12px;
  margin-top: 16px;
}

.step-card {
  display: block;
  width: 100%;
  overflow: hidden;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-xlarge);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  box-shadow: none;
  transition: background var(--duration-fast) var(--curve-easy-ease),
    border-color var(--duration-fast) var(--curve-easy-ease),
    box-shadow var(--duration-fast) var(--curve-easy-ease);
}

.step-card.has-subitems {
  grid-column: 1 / -1;
}

.step-card:hover {
  border-color: var(--neutral-stroke-1);
  box-shadow: var(--shadow-2);
}

.step-card.is-active {
  border-color: var(--brand-stroke-1);
  box-shadow: inset 0 0 0 1px var(--brand-stroke-1);
}

.step-card.is-complete {
  background: var(--neutral-background-1);
}

.step-card.is-locked,
.step-card.is-blocked {
  color: var(--neutral-foreground-disabled);
  background: var(--neutral-background-2);
}

.step-card.is-locked .step-summary,
.step-card.is-blocked .step-summary {
  color: var(--neutral-foreground-disabled);
}

.step-card-main {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  width: 100%;
  padding: 14px;
  border: 0;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.step-card-main:hover {
  background: var(--neutral-background-2);
}

.step-card-main:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: -2px;
}

.step-index {
  flex: none;
  display: grid;
  place-items: center;
  width: 32px;
  height: 32px;
  border-radius: var(--radius-medium);
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
}

.step-card.is-active .step-index {
  background: var(--brand-background);
  color: var(--neutral-foreground-on-brand);
}

.step-card.is-complete .step-index {
  background: var(--success-background);
  color: var(--success-foreground);
}

.step-index svg {
  width: 16px;
  height: 16px;
}

.step-main {
  flex: 1;
  min-width: 0;
}

.step-title-row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 8px;
}

.step-title {
  font-size: 14px;
  font-weight: 600;
  line-height: 1.35;
}

.step-summary {
  display: -webkit-box;
  margin: 4px 0 0;
  overflow: hidden;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  line-height: 1.45;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
}

.step-badge {
  flex: none;
  display: inline-flex;
  align-items: center;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-small);
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
  white-space: nowrap;
}

.step-card.is-complete .step-badge {
  background: var(--success-background);
  color: var(--success-foreground);
}

.step-card.is-active .step-badge {
  background: var(--brand-background-2);
  color: var(--brand-foreground-1);
}

.step-subitems {
  padding: 0 14px 14px 58px;
}

.subitem-tree,
.subitem-children {
  margin: 0;
  padding: 0;
  list-style: none;
}

.subitem-tree {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
  gap: 10px;
  align-items: start;
}

.subitem-node {
  min-width: 0;
}

.subitem-tree > .subitem-node {
  overflow: hidden;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-large);
  background: var(--neutral-background-2);
}

.subitem-children {
  position: relative;
  display: grid;
  gap: 2px;
  margin-left: 18px;
  padding: 2px 8px 8px 13px;
  border-left: 1px solid var(--neutral-stroke-2);
}

.subitem-children > .subitem-node > .subitem-row::before {
  content: "";
  position: absolute;
  top: 17px;
  left: -13px;
  width: 9px;
  border-top: 1px solid var(--neutral-stroke-2);
}

.subitem-row {
  position: relative;
  display: flex;
  align-items: flex-start;
  gap: 8px;
  width: 100%;
  min-height: 32px;
  padding: 6px 8px;
  border: 0;
  border-radius: var(--radius-medium);
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.subitem-row:hover {
  background: var(--neutral-background-1);
}

.subitem-row:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.subitem-tree > .subitem-node > .subitem-row.is-parent {
  align-items: center;
  min-height: 40px;
  padding: 8px 10px;
  border-radius: 0;
  border-bottom: 1px solid var(--neutral-stroke-2);
}

.subitem-tree > .subitem-node > .subitem-row.is-parent:hover {
  background: var(--neutral-background-3);
}

.subitem-branch-icon {
  flex: none;
  margin-top: 1px;
  display: grid;
  place-items: center;
  width: 24px;
  height: 24px;
  border-radius: var(--radius-small);
  background: var(--brand-background-2);
  color: var(--brand-foreground-1);
}

.subitem-branch-icon .icon {
  width: 14px;
  height: 14px;
}

.subitem-kind {
  flex: none;
  margin-top: 1px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 84px;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-small);
  font-size: 10px;
  font-weight: 700;
  letter-spacing: .02em;
  text-transform: uppercase;
}

.subitem-kind.is-dev {
  background: var(--brand-background-2);
  color: var(--brand-foreground-1);
}

.subitem-kind.is-build {
  background: var(--success-background);
  color: var(--success-foreground);
}

.subitem-kind.is-deployment {
  background: var(--neutral-background-4);
  color: var(--neutral-foreground-2);
}

.subitem-text {
  display: flex;
  flex: 1;
  flex-direction: column;
  min-width: 0;
}

.subitem-primary {
  overflow-wrap: anywhere;
  font-size: 12px;
  font-weight: 600;
  line-height: 1.35;
}

.subitem-detail {
  margin-top: 1px;
  color: var(--neutral-foreground-3);
  font-size: 11px;
  line-height: 1.4;
  overflow-wrap: anywhere;
}

.subitem-count {
  flex: none;
  margin-top: 3px;
  color: var(--neutral-foreground-3);
  font-size: 11px;
  white-space: nowrap;
}

.subitem-chevron {
  flex: none;
  margin-top: 4px;
  display: grid;
  place-items: center;
  width: 16px;
  height: 16px;
  color: var(--neutral-foreground-3);
}

.subitem-chevron .icon {
  width: 12px;
  height: 12px;
}

.action-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid var(--neutral-stroke-2);
}

.action-spacer {
  flex: 1;
}

.action-reason {
  width: 100%;
  margin: 0;
  color: var(--neutral-foreground-3);
  font-size: 12px;
}

/* Fluent buttons */

.btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
  min-height: 32px;
  padding: 0 12px;
  border: 1px solid transparent;
  border-radius: var(--radius-medium);
  font: inherit;
  font-size: 14px;
  font-weight: 600;
  line-height: 1;
  text-decoration: none;
  cursor: pointer;
  transition: background var(--duration-fast) var(--curve-easy-ease),
    border-color var(--duration-fast) var(--curve-easy-ease);
}

.btn:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 2px;
}

.btn-primary {
  background: var(--brand-background);
  color: var(--neutral-foreground-on-brand);
}

.btn-primary:hover {
  background: var(--brand-background-hover);
}

.btn-primary:active {
  background: var(--brand-background-pressed);
}

.btn-secondary {
  background: var(--neutral-background-1);
  border-color: var(--neutral-stroke-1);
  color: var(--neutral-foreground-1);
}

.btn-secondary:hover {
  background: var(--neutral-background-3);
}

.btn-ghost {
  background: transparent;
  color: var(--neutral-foreground-2);
}

.btn-ghost:hover {
  background: var(--neutral-background-3);
}

.btn-danger {
  background: transparent;
  color: var(--danger-foreground);
}

.btn-danger:hover {
  background: var(--danger-background);
}

.btn:disabled,
.btn[aria-disabled="true"] {
  background: var(--neutral-background-disabled);
  border-color: var(--neutral-stroke-2);
  color: var(--neutral-foreground-disabled);
  cursor: not-allowed;
}

.icon-button {
  padding: 4px 8px;
  border: 1px solid transparent;
  border-radius: var(--radius-medium);
  background: transparent;
  color: var(--neutral-foreground-2);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}

.icon-button:hover {
  background: var(--neutral-background-3);
}

.icon-button:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.prompt-actions {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid var(--neutral-stroke-2);
}

/* Fluent TextField and segmented control */

.field {
  display: grid;
  gap: 4px;
  margin-top: 16px;
}

.field label {
  color: var(--neutral-foreground-1);
  font-size: 14px;
  font-weight: 600;
}

.field-control {
  display: flex;
  gap: 8px;
}

.field-control > .btn {
  flex: 0 0 auto;
}

.field-input {
  width: 100%;
  min-height: 32px;
  padding: 4px 10px;
  border: 1px solid var(--neutral-stroke-1);
  border-bottom: 2px solid var(--neutral-stroke-accessible);
  border-radius: var(--radius-medium);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  font: inherit;
  font-size: 14px;
}

.field-input:hover {
  border-bottom-color: var(--neutral-foreground-2);
}

.field-input:focus {
  outline: none;
  border-color: var(--neutral-stroke-1);
  border-bottom: 2px solid var(--brand-stroke-1);
}

.field-hint {
  color: var(--neutral-foreground-3);
  font-size: 12px;
}

.search-field {
  margin-top: 16px;
}

.search-control {
  position: relative;
  display: flex;
  align-items: center;
}

.search-control .search-icon {
  position: absolute;
  left: 10px;
  z-index: 1;
  width: 16px;
  height: 16px;
  color: var(--neutral-foreground-3);
  pointer-events: none;
}

.search-input {
  padding-left: 32px;
  padding-right: 64px;
}

.search-input::-webkit-search-cancel-button {
  display: none;
}

.search-clear {
  position: absolute;
  right: 4px;
  height: 24px;
  padding: 0 6px;
  border: 1px solid transparent;
  border-radius: var(--radius-small);
  background: transparent;
  color: var(--brand-foreground-1);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}

.search-clear:hover {
  background: var(--neutral-background-3);
}

.search-clear:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.no-results {
  margin: 12px 0 0;
  text-align: center;
}

.field-error {
  position: relative;
  padding: 6px 8px 6px 26px;
  border-radius: var(--radius-medium);
  background: var(--danger-background);
  color: var(--danger-foreground);
  font-size: 12px;
  font-weight: 600;
}

.field-error::before {
  content: "!";
  position: absolute;
  left: 8px;
  top: 6px;
  display: grid;
  place-items: center;
  width: 14px;
  height: 14px;
  border-radius: 50%;
  background: var(--danger-foreground);
  color: var(--neutral-background-1);
  font-size: 10px;
  font-weight: 700;
}

.segmented {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 16px;
}

.segmented .btn {
  min-width: 96px;
}

/* Fluent tables and description lists */

.blocks {
  display: grid;
  gap: 16px;
  margin-top: 16px;
}

/* A prompt's queued summary tables already sit inside their own card. */
.context-card .blocks {
  margin-top: 0;
}

.block-title {
  margin: 0 0 8px;
  color: var(--neutral-foreground-2);
  font-size: 14px;
  font-weight: 600;
}

.metrics {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 8px;
}

.metric {
  padding: 10px 12px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-large);
  background: var(--neutral-background-2);
}

.metric-value {
  display: block;
  color: var(--neutral-foreground-1);
  font-size: 20px;
  font-weight: 600;
  line-height: 1.2;
}

.metric-label {
  display: block;
  margin-top: 2px;
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
}

.metric-detail {
  display: block;
  margin-top: 2px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
}

.table-wrap {
  overflow: auto;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-large);
}

.data-table {
  width: 100%;
  min-width: 520px;
  border-collapse: collapse;
  font-size: 13px;
}

.data-table th {
  padding: 8px 12px;
  border-bottom: 1px solid var(--neutral-stroke-2);
  background: var(--neutral-background-2);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
  text-align: left;
  white-space: nowrap;
}

.data-table td {
  padding: 8px 12px;
  border-bottom: 1px solid var(--neutral-stroke-3);
  color: var(--neutral-foreground-1);
  vertical-align: top;
}

.data-table tr:last-child td {
  border-bottom: 0;
}

.kv {
  display: grid;
  grid-template-columns: minmax(140px, 0.4fr) 1fr;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-large);
  overflow: hidden;
}

.kv-key,
.kv-value {
  padding: 8px 12px;
  border-bottom: 1px solid var(--neutral-stroke-3);
  font-size: 13px;
}

.kv-key {
  background: var(--neutral-background-2);
  color: var(--neutral-foreground-2);
  font-weight: 600;
}

.kv-value {
  color: var(--neutral-foreground-1);
}

.resource-list,
.file-list,
.next-links {
  display: grid;
  gap: 4px;
}

.resource,
.file-row,
.next-link {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: 36px;
  padding: 6px 10px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-medium);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  font-size: 13px;
}

.file-row {
  width: 100%;
  font: inherit;
  text-align: left;
  cursor: pointer;
}

.file-row:hover {
  background: var(--neutral-background-2);
  border-color: var(--neutral-stroke-1);
}

.file-row:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.status-dot {
  flex: none;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--neutral-foreground-3);
}

.status-Added {
  background: var(--success-foreground);
}

.status-Modified {
  background: var(--warning-foreground);
}

.status-Deleted {
  background: var(--danger-foreground);
}

.status-chip {
  flex: none;
  display: inline-flex;
  align-items: center;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-small);
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
  text-transform: none;
}

.file-path {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  color: var(--neutral-foreground-1);
  font-family: var(--font-family-monospace);
  font-size: 12px;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.resource-action {
  flex: none;
  color: var(--neutral-foreground-1);
  font-weight: 600;
}

.resource-target {
  color: var(--neutral-foreground-3);
}

.file-preview {
  max-height: 400px;
  margin: 0;
  padding: 12px;
  overflow: auto;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-large);
  background: var(--neutral-background-2);
  color: var(--neutral-foreground-1);
  font-family: var(--font-family-monospace);
  font-size: 12px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-word;
}

/* Fluent code/diff surface */

.diff-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 16px;
  flex-wrap: wrap;
}

.diff-file {
  margin: 4px 0 0;
  color: var(--neutral-foreground-3);
  font-family: var(--font-family-monospace);
  font-size: 12px;
}

.diff-legend {
  display: flex;
  gap: 12px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  font-weight: 600;
}

.diff-scroll {
  max-height: 58vh;
  margin-top: 16px;
  overflow: auto;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-large);
  background: var(--neutral-background-1);
}

.diff-table {
  min-width: 760px;
  font-family: var(--font-family-monospace);
  font-size: 12px;
  line-height: 1.5;
}

.diff-header {
  position: sticky;
  top: 0;
  z-index: 2;
  display: grid;
  grid-template-columns: 1fr 1fr;
  border-bottom: 1px solid var(--neutral-stroke-2);
  background: var(--neutral-background-2);
  color: var(--neutral-foreground-2);
  font-family: var(--font-family-base);
  font-size: 12px;
  font-weight: 600;
}

.diff-header span {
  padding: 6px 10px;
}

.diff-header span + span {
  border-left: 1px solid var(--neutral-stroke-2);
}

.diff-row {
  display: grid;
  grid-template-columns: 1fr 1fr;
}

.diff-row + .diff-row {
  border-top: 1px solid var(--neutral-stroke-3);
}

.diff-cell {
  min-height: 18px;
  padding: 0 10px;
  white-space: pre-wrap;
  word-break: break-word;
}

.diff-cell + .diff-cell {
  border-left: 1px solid var(--neutral-stroke-3);
}

.diff-row.is-deleted .diff-cell:first-child {
  background: var(--danger-background);
  color: var(--danger-foreground);
}

.diff-row.is-added .diff-cell:last-child {
  background: var(--success-background);
  color: var(--success-foreground);
}

.diff-row.is-modified .diff-cell:first-child {
  background: var(--danger-background);
  color: var(--danger-foreground);
}

.diff-row.is-modified .diff-cell:last-child {
  background: var(--success-background);
  color: var(--success-foreground);
}

.diff-row.is-notice .diff-cell {
  padding: 4px 10px;
  background: var(--warning-background);
  color: var(--warning-foreground);
  font-family: var(--font-family-base);
  font-weight: 600;
}

/* Fluent result page */

.complete-hero {
  display: grid;
  justify-items: center;
  gap: 8px;
  padding: 8px 0 16px;
  text-align: center;
}

.complete-tick {
  display: grid;
  place-items: center;
  width: 48px;
  height: 48px;
  margin-bottom: 4px;
  border-radius: 50%;
  background: var(--success-background);
  color: var(--success-foreground);
}

.complete-tick svg {
  width: 24px;
  height: 24px;
}

.complete-hero h1 {
  font-size: clamp(22px, 2.8vw, 28px);
}

.complete-hero .lede {
  max-width: 60ch;
}

.summary-grid {
  display: grid;
  grid-template-columns: minmax(140px, 0.35fr) 1fr;
  margin: 16px 0 0;
  border-top: 1px solid var(--neutral-stroke-2);
}

.summary-item {
  display: contents;
}

.summary-label,
.summary-value {
  margin: 0;
  padding: 8px 0;
  border-bottom: 1px solid var(--neutral-stroke-3);
  font-size: 13px;
}

.summary-label {
  color: var(--neutral-foreground-3);
  font-weight: 600;
}

.summary-value {
  color: var(--neutral-foreground-1);
  overflow-wrap: anywhere;
}

.next-link {
  justify-content: space-between;
  text-decoration: none;
  transition: background var(--duration-fast) var(--curve-easy-ease);
}

.next-link:hover {
  background: var(--neutral-background-2);
  border-color: var(--neutral-stroke-1);
}

.next-link:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.next-link-arrow {
  color: var(--neutral-foreground-3);
  font-size: 16px;
  line-height: 1;
}

.finished-note {
  margin-top: 20px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
  text-align: center;
}

/* Fluent MessageBar (error) */

.error-details {
  max-height: 280px;
  margin: 16px 0 0;
  padding: 10px 12px;
  overflow: auto;
  border: 1px solid var(--danger-border);
  border-radius: var(--radius-medium);
  background: var(--danger-background);
  color: var(--danger-foreground);
  font-family: var(--font-family-monospace);
  font-size: 12px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-word;
}

/* Sign-in modal (device code) */

.device-banner {
  position: fixed;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  z-index: 60;
  display: flex;
  align-items: flex-start;
  gap: 12px;
  width: min(560px, calc(100vw - 40px));
  max-height: calc(100vh - 40px);
  overflow: auto;
  margin: 0;
  padding: 20px;
  border: 1px solid var(--warning-border);
  border-radius: var(--radius-large);
  background: var(--warning-background);
  box-shadow: var(--shadow-16);
}

body.device-signin::before {
  content: "";
  position: fixed;
  inset: 0;
  z-index: 55;
  background: var(--busy-scrim);
  backdrop-filter: blur(2px);
}

body.device-signin #stage {
  pointer-events: none;
}

.device-mark {
  flex: none;
  display: grid;
  place-items: center;
  width: 20px;
  height: 20px;
  margin-top: 0;
  color: var(--warning-foreground);
}

.device-mark .icon {
  width: 20px;
  height: 20px;
}

.icon {
  display: inline-block;
  flex: none;
  width: 16px;
  height: 16px;
  vertical-align: middle;
}

.device-copy {
  flex: 1;
  min-width: 0;
}

.device-copy .eyebrow {
  color: var(--warning-foreground);
  margin-bottom: 2px;
}

.device-message {
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  color: var(--neutral-foreground-1);
  font-family: var(--font-family-monospace);
  font-size: 12px;
  line-height: 1.5;
  white-space: pre-wrap;
  word-break: break-word;
}

.device-actions {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 8px;
}

/* Fluent panel / activity drawer */

.activity-fab {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  height: 28px;
  padding: 0 8px;
  border: 1px solid transparent;
  border-radius: var(--radius-medium);
  background: transparent;
  color: var(--neutral-foreground-2);
  font: inherit;
  font-size: 12px;
  font-weight: 600;
  cursor: pointer;
}

.activity-fab:hover {
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-1);
}

.activity-fab:focus-visible {
  outline: 2px solid var(--brand-stroke-1);
  outline-offset: 1px;
}

.activity-fab .icon {
  width: 16px;
  height: 16px;
}

.theme-toggle {
  width: 28px;
  height: 28px;
  padding: 0;
  display: inline-grid;
  place-items: center;
}

.theme-toggle .icon {
  width: 16px;
  height: 16px;
}

.activity-count {
  display: inline-grid;
  place-items: center;
  min-width: 20px;
  height: 20px;
  padding: 0 6px;
  border-radius: var(--radius-circular);
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-2);
  font-size: 12px;
  font-weight: 600;
}

.activity-drawer {
  position: fixed;
  right: 20px;
  bottom: 72px;
  z-index: 41;
  display: none;
  flex-direction: column;
  width: min(440px, calc(100vw - 24px));
  max-height: min(520px, 60vh);
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-xlarge);
  background: var(--neutral-background-1);
  box-shadow: var(--shadow-64);
  overflow: hidden;
}

.activity-drawer.is-open {
  display: flex;
}

.activity-fab[aria-expanded="true"] {
  background: var(--neutral-background-3);
  color: var(--neutral-foreground-1);
}

.activity-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 12px 16px;
  border-bottom: 1px solid var(--neutral-stroke-2);
}

.activity-head h2 {
  font-size: 16px;
}

.activity-log {
  padding: 8px 16px 12px;
  overflow: auto;
  font-size: 12px;
  line-height: 1.5;
}

.log-entry {
  display: flex;
  gap: 8px;
  padding: 1px 0;
}

.log-time {
  flex: none;
  color: var(--neutral-foreground-3);
}

.log-text {
  min-width: 0;
  color: var(--neutral-foreground-2);
  white-space: pre-wrap;
  word-break: break-word;
}

.log-entry.is-error .log-text {
  color: var(--danger-foreground);
}

.log-entry.is-warn .log-text {
  color: var(--warning-foreground);
}

.log-entry.is-success .log-text {
  color: var(--success-foreground);
}

.log-entry.is-muted .log-text {
  color: var(--neutral-foreground-3);
}

/* Page footer and toast */

.shell-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  margin-top: 24px;
  color: var(--neutral-foreground-3);
  font-size: 12px;
}

.footer-status {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
}

.stage-inner-working {
  min-height: calc(100vh - 260px);
  place-items: center;
}

.working-card {
  width: min(560px, 100%);
  padding: 32px;
  text-align: center;
}

.working-card .lede {
  margin-left: auto;
  margin-right: auto;
}

.working-thinking {
  justify-content: center;
  margin-top: 20px;
}

.working-card .busy-spinner {
  width: 36px;
  height: 36px;
}

.working-output {
  margin-top: 20px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-medium);
  background: var(--neutral-background-2);
  text-align: left;
  overflow: hidden;
}

.working-output-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 8px 12px;
  border-bottom: 1px solid var(--neutral-stroke-2);
  color: var(--neutral-foreground-3);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}

.working-output-log {
  max-height: 220px;
  overflow: auto;
  padding: 8px 12px;
  font-family: ui-monospace, SFMono-Regular, Consolas, 'Liberation Mono', monospace;
  font-size: 12px;
  line-height: 1.5;
}

.working-output-log .log-entry {
  padding: 1px 0;
}

.working-output-empty {
  color: var(--neutral-foreground-3);
}

.busy-indicator {
  position: fixed;
  left: 50%;
  top: 50%;
  transform: translate(-50%, -50%);
  z-index: 46;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 16px;
  width: min(360px, calc(100vw - 40px));
  padding: 28px 30px 26px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-xlarge);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  font-size: 14px;
  font-weight: 600;
  line-height: 1.45;
  text-align: center;
  box-shadow: var(--shadow-16);
}

.busy-indicator .busy-spinner {
  width: 48px;
  height: 48px;
  transform-origin: center;
  animation: spin 0.9s linear infinite;
}

.busy-spinner-track,
.busy-spinner-arc {
  fill: none;
  stroke-width: 4.5;
}

.busy-spinner-track {
  stroke: var(--neutral-background-5);
}

.busy-spinner-arc {
  stroke: var(--brand-foreground-1);
  stroke-linecap: round;
  stroke-dasharray: 78 200;
}

body.busy-overlay::before {
  content: "";
  position: fixed;
  inset: 0;
  z-index: 45;
  background: var(--busy-scrim);
  backdrop-filter: blur(2px);
  animation: busy-scrim-in 120ms ease-out;
}

body.busy-overlay #stage {
  pointer-events: none;
}

@keyframes busy-scrim-in {
  from {
    opacity: 0;
  }
  to {
    opacity: 1;
  }
}

@media (prefers-reduced-motion: reduce) {
  .busy-indicator .busy-spinner {
    animation-duration: 2.4s;
  }
}

.toast {
  position: fixed;
  left: 20px;
  bottom: 20px;
  z-index: 50;
  max-width: min(420px, calc(100vw - 40px));
  padding: 8px 12px;
  border: 1px solid var(--neutral-stroke-2);
  border-radius: var(--radius-medium);
  background: var(--neutral-background-1);
  color: var(--neutral-foreground-1);
  font-size: 13px;
  font-weight: 600;
  box-shadow: var(--shadow-16);
}

@media (max-width: 720px) {
  .shell {
    padding-top: 12px;
  }

  .brand-logo {
    height: 40px;
  }

  .card {
    padding: 16px;
    border-radius: var(--radius-large);
  }

  .stage {
    padding-top: 16px;
  }

  .step-grid {
    grid-template-columns: 1fr;
  }

  .step-subitems {
    padding-left: 14px;
  }

  .subitem-tree {
    grid-template-columns: 1fr;
  }

  .segmented .btn {
    flex: 1;
  }

  .kv {
    grid-template-columns: 1fr;
  }

  .kv-key {
    padding-bottom: 2px;
    border-bottom: 0;
  }

  .kv-value {
    padding-top: 0;
  }

  .action-bar .btn,
  .prompt-actions .btn {
    flex: 1;
  }

  .diff-scroll {
    max-height: 48vh;
  }

  .activity-drawer {
    right: 12px;
    bottom: 64px;
  }
}

@media (prefers-reduced-motion: reduce) {
  *,
  *::before,
  *::after {
    animation: none !important;
    transition: none !important;
  }
}

'@

$script:SetupWebUiJavaScript = @'
(function () {
  'use strict';

  var token = new URLSearchParams(window.location.search).get('token') || '';
  var stage = document.getElementById('stage');
  var connection = document.getElementById('connection');
  var connectionText = document.getElementById('connection-text');
  var providerPill = document.getElementById('provider-pill');
  var repositoryChip = document.getElementById('repository-chip');
  var repositoryName = document.getElementById('repository-name');
  var versionPill = document.getElementById('version-pill');
  var deviceBanner = document.getElementById('device-banner');
  var deviceMessage = document.getElementById('device-message');
  var deviceLink = document.getElementById('device-link');
  var deviceCopy = document.getElementById('device-copy');
  var busyIndicator = document.getElementById('busy-indicator');
  var busyMessage = document.getElementById('busy-message');
  var activityFab = document.getElementById('activity-fab');
  var activityDrawer = document.getElementById('activity-drawer');
  var activityLog = document.getElementById('activity-log');
  var activityCount = document.getElementById('activity-count');
  var activityClose = document.getElementById('activity-close');
  var themeToggle = document.getElementById('theme-toggle');
  var toast = document.getElementById('toast');

  var lastVersion = -1;
  var lastInteractiveVersion = 0;
  var actionInteractiveVersion = 0;
  var lastDeviceCode = '';
  var lastActivitySignature = '';
  var currentPromptId = null;
  var currentRenderSignature = null;
  var promptBusy = false;
  var finished = false;
  var polling = false;
  var pollingTimer = null;
  var toastTimer = null;
  var completionAcknowledged = false;

  function applyTheme(theme) {
    if (theme === 'dark') {
      document.documentElement.setAttribute('data-theme', 'dark');
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
    var nextLabel = theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
    themeToggle.innerHTML = '<svg class="icon" aria-hidden="true"><use href="#icon-' + (theme === 'dark' ? 'sun' : 'moon') + '"></use></svg>';
    themeToggle.setAttribute('aria-label', nextLabel);
    themeToggle.title = nextLabel;
  }

  function asArray(value) {
    if (Array.isArray(value)) {
      return value;
    }
    if (value === null || value === undefined) {
      return [];
    }
    return [value];
  }

  function icon(name, className) {
    return '<svg class="icon' + (className ? ' ' + className : '') + '" aria-hidden="true"><use href="#icon-' + name + '"></use></svg>';
  }

  function escapeHtml(value) {
    return String(value === null || value === undefined ? '' : value).replace(/[&<>"']/g, function (character) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character];
    });
  }

  function showToast(message) {
    toast.textContent = message;
    toast.hidden = false;
    if (toastTimer) {
      window.clearTimeout(toastTimer);
    }
    toastTimer = window.setTimeout(function () {
      toast.hidden = true;
    }, 4200);
  }

  function setConnection(online, message) {
    connection.classList.toggle('is-online', online);
    connection.classList.toggle('is-offline', !online);
    connectionText.textContent = message || (online ? 'Connected' : 'Reconnecting');
  }

  function safeUrl(value) {
    var text = String(value === null || value === undefined ? '' : value);
    return /^https?:\/\//i.test(text) ? text : '#';
  }

  function stopPolling() {
    finished = true;
    if (pollingTimer) {
      window.clearTimeout(pollingTimer);
      pollingTimer = null;
    }
  }

  // The action response only confirms the queue. Setup may run for seconds before
  // it publishes the next state, so progress must start on the click.
  function showBusy(message) {
    if (stage.querySelector('.working-card')) {
      return;
    }
    // Sign-in is its own modal and must stay above busy progress.
    if (!deviceBanner.hidden) {
      return;
    }
    if (busyMessage) {
      busyMessage.textContent = message || 'Working on the next step...';
    }
    if (busyIndicator) {
      busyIndicator.hidden = false;
    }
    document.body.classList.add('busy-overlay');
  }

  function hideBusy() {
    if (busyIndicator) {
      busyIndicator.hidden = true;
    }
    document.body.classList.remove('busy-overlay');
  }

  function updateBusyMessage(message) {
    if (promptBusy && busyMessage && message) {
      busyMessage.textContent = message;
    }
  }

  async function postAction(payload, quiet) {
    if (promptBusy) {
      return;
    }
    var body = Object.assign({ id: currentPromptId }, payload);
    if (!quiet) {
      promptBusy = true;
      actionInteractiveVersion = lastInteractiveVersion;
      showBusy('Working on the next step...');
    }
    try {
      var response = await fetch('/api/action?token=' + encodeURIComponent(token), {
        method: 'POST',
        cache: 'no-store',
        headers: {
          'Content-Type': 'application/json',
          'X-Setup-Token': token
        },
        body: JSON.stringify(body)
      });
      if (!response.ok) {
        throw new Error('Setup did not accept this action (HTTP ' + response.status + ').');
      }
      if (!quiet) {
        scheduleTick(90);
      }
    } catch (error) {
      if (!quiet) {
        promptBusy = false;
        hideBusy();
        showToast(error && error.message ? error.message : 'Could not reach setup.');
      }
    }
  }

  function scheduleTick(delay) {
    if (finished) {
      return;
    }
    if (pollingTimer) {
      window.clearTimeout(pollingTimer);
    }
    pollingTimer = window.setTimeout(tick, delay);
  }

  async function tick() {
    if (finished || polling) {
      return;
    }
    polling = true;
    pollingTimer = null;
    try {
      var response = await fetch('/api/state?token=' + encodeURIComponent(token), { cache: 'no-store' });
      if (!response.ok) {
        throw new Error('HTTP ' + response.status);
      }
      var payload = await response.json();
      var state = payload.state || {};
      var interactiveVersion = state.interactiveVersion || 0;
      setConnection(true);
      updateDeviceCode(payload.deviceCode || '');

      if (promptBusy) {
        if (interactiveVersion !== actionInteractiveVersion) {
          // A new prompt or board is ready; the previous interactive state is no
          // longer the place where setup is running.
          promptBusy = false;
          lastInteractiveVersion = interactiveVersion;
          lastVersion = payload.version;
          hideBusy();
          render(payload);
          polling = false;
          if (!finished) {
            scheduleTick(420);
          }
          return;
        }

        lastInteractiveVersion = interactiveVersion;
        if (payload.busy) {
          // The working screen owns the spinner once setup publishes work.
          hideBusy();
        } else {
          // Activity updates can arrive before setup clears the old prompt. Keep the
          // progress pill so the stale screen is never shown as if it were current.
          showBusy(payload.busy);
        }
        if (payload.version !== lastVersion) {
          lastVersion = payload.version;
          render(payload);
        } else {
          updateBusyMessage(payload.busy);
        }
      } else if (payload.version !== lastVersion) {
        lastVersion = payload.version;
        lastInteractiveVersion = interactiveVersion;
        render(payload);
      } else {
        updateBusyMessage(payload.busy);
      }
    } catch (error) {
      setConnection(false);
    }
    polling = false;
    if (!finished) {
      scheduleTick(promptBusy ? 160 : 420);
    }
  }

  function render(payload) {
    var state = payload.state || {};
    document.title = (state.title || 'Setup') + ' - ALM4Dataverse';
    providerPill.textContent = state.app || 'Setup';
    versionPill.textContent = state.version || 'Development';

    var repositoryText = state.repository || '';
    repositoryChip.hidden = !repositoryText;
    if (repositoryText) {
      repositoryName.textContent = repositoryText;
      repositoryChip.title = repositoryText;
      if (state.repositoryUrl) {
        repositoryChip.href = state.repositoryUrl;
        repositoryChip.removeAttribute('aria-disabled');
      } else {
        repositoryChip.removeAttribute('href');
        repositoryChip.setAttribute('aria-disabled', 'true');
      }
    }

    renderActivity(state.activity);

    var prompt = state.prompt || null;
    var wizard = state.wizard || null;
    var signature;
    if (prompt) {
      signature = 'prompt:' + prompt.id;
    } else if (wizard) {
      signature = 'wizard:' + JSON.stringify(wizard);
    } else {
      signature = 'working:' + (state.section || '') + ':' + (state.busy || '');
    }

    if (signature !== currentRenderSignature) {
      currentRenderSignature = signature;
      if (prompt) {
        currentPromptId = prompt.id;
        renderPrompt(prompt, state, wizard);
      } else if (wizard) {
        currentPromptId = null;
        renderWizard(wizard, state);
      } else {
        currentPromptId = null;
        renderWorking(state);
      }
    }

    if (!prompt && !wizard) {
      hideBusy();
      updateWorkingOutput(state.activity);
    }

    if (state.finished) {
      stopPolling();
    }
  }

  function renderActivity(entries) {
    entries = asArray(entries);
    activityCount.textContent = String(entries.length);
    var signature = JSON.stringify(entries.slice(-1));
    if (signature === lastActivitySignature) {
      return;
    }
    lastActivitySignature = signature;
    var wasNearBottom = activityLog.scrollTop + activityLog.clientHeight >= activityLog.scrollHeight - 24;
    activityLog.innerHTML = entries.map(function (entry) {
      var tone = entry.tone || 'info';
      return '<div class="log-entry is-' + escapeHtml(tone) + '">' +
        '<span class="log-time">' + escapeHtml(entry.time || '') + '</span>' +
        '<span class="log-text">' + escapeHtml(entry.text || '') + '</span>' +
        '</div>';
    }).join('');
    if (wasNearBottom || activityDrawer.classList.contains('is-open')) {
      activityLog.scrollTop = activityLog.scrollHeight;
    }
  }

  function updateDeviceCode(message) {
    if (message === lastDeviceCode) {
      return;
    }
    lastDeviceCode = message;
    if (!message) {
      deviceBanner.hidden = true;
      document.body.classList.remove('device-signin');
      return;
    }
    var wasHidden = deviceBanner.hidden;
    deviceBanner.hidden = false;
    document.body.classList.add('device-signin');
    // Sign-in owns the modal layer; busy progress must not cover its instructions.
    hideBusy();
    deviceMessage.textContent = message;
    var match = message.match(/https?:\/\/[^\s]+/i);
    if (match) {
      deviceLink.href = match[0];
      deviceLink.hidden = false;
    } else {
      deviceLink.hidden = true;
    }
    var codeMatch = message.match(/(?:one-time code|verification code|enter the code)[^A-Z0-9]*([A-Z0-9][A-Z0-9-]{3,})/i);
    deviceCopy.setAttribute('data-code', codeMatch ? codeMatch[1] : '');
    if (wasHidden) {
      if (!deviceLink.hidden) {
        deviceLink.focus();
      } else {
        deviceCopy.focus();
      }
    }
  }

  function renderGuidance(prompt) {
    var lines = asArray(prompt.guidance);
    var html = '';
    if (lines.length) {
      html += '<ul class="guidance">' + lines.map(function (line) {
        return '<li>' + escapeHtml(line) + '</li>';
      }).join('') + '</ul>';
    }
    if (prompt.helpUrl) {
      html += '<a class="help-link" href="' + escapeAttribute(safeUrl(prompt.helpUrl)) + '" target="_blank" rel="noreferrer noopener">Open the setup guide <span aria-hidden="true">&rarr;</span></a>';
    }
    return html;
  }

  function escapeAttribute(value) {
    return escapeHtml(value);
  }

  function renderBlocks(blocks) {
    blocks = asArray(blocks);
    if (!blocks.length) {
      return '';
    }
    return '<div class="blocks">' + blocks.map(function (block) {
      switch (block.type) {
        case 'metrics':
          return renderMetrics(block);
        case 'table':
          return renderTable(block);
        case 'keyvalue':
          return renderKeyValue(block);
        case 'resources':
          return renderResources(block);
        case 'files':
          return renderFileSummary(block);
        case 'file':
          return '<section><p class="block-title">' + escapeHtml(block.heading || block.path || 'File') + '</p>' +
            '<pre class="file-preview">' + escapeHtml(block.content || '') + '</pre></section>';
        default:
          return '';
      }
    }).join('') + '</div>';
  }

  function renderMetrics(block) {
    var cards = asArray(block.cards);
    return '<section><p class="block-title">' + escapeHtml(block.heading || 'Overview') + '</p><div class="metrics">' +
      cards.map(function (card) {
        return '<div class="metric">' +
          '<span class="metric-value">' + escapeHtml(card.value) + '</span>' +
          '<span class="metric-label">' + escapeHtml(card.label) + '</span>' +
          (card.detail ? '<span class="metric-detail">' + escapeHtml(card.detail) + '</span>' : '') +
          '</div>';
      }).join('') + '</div></section>';
  }

  function renderTable(block) {
    var columns = asArray(block.columns);
    var rows = asArray(block.rows);
    return '<section><p class="block-title">' + escapeHtml(block.heading || 'Details') + '</p><div class="table-wrap">' +
      '<table class="data-table"><thead><tr>' + columns.map(function (column) {
        return '<th>' + escapeHtml(column) + '</th>';
      }).join('') + '</tr></thead><tbody>' + rows.map(function (row) {
        return '<tr>' + asArray(row).map(function (cell) {
          return '<td>' + escapeHtml(cell) + '</td>';
        }).join('') + '</tr>';
      }).join('') + '</tbody></table></div></section>';
  }

  function renderKeyValue(block) {
    var values = asArray(block.values);
    return '<section><p class="block-title">' + escapeHtml(block.heading || 'Summary') + '</p><div class="kv">' +
      values.map(function (entry) {
        return '<div class="kv-key">' + escapeHtml(entry.label) + '</div><div class="kv-value">' + escapeHtml(entry.value) + '</div>';
      }).join('') + '</div></section>';
  }

  function renderResources(block) {
    var items = asArray(block.items);
    return '<section><p class="block-title">' + escapeHtml(block.heading || 'Deferred resource changes') + ' (' + items.length + ')</p>' +
      (items.length ? '<div class="resource-list">' + items.map(function (item) {
        return '<div class="resource"><span class="resource-action">' + escapeHtml(item.action) + '</span>' +
          '<span>' + escapeHtml(item.resource) + '</span>' +
          '<span class="resource-target">' + escapeHtml(item.target) + '</span></div>' +
          (item.details ? '<p class="field-hint">' + escapeHtml(item.details) + '</p>' : '');
      }).join('') + '</div>' : '<p class="field-hint">No external resources will be modified by this operation.</p>') +
      (block.note ? '<p class="field-hint" style="margin-top:10px">' + escapeHtml(block.note) + '</p>' : '') +
      '</section>';
  }

  function renderFileSummary(block) {
    var files = asArray(block.files);
    return '<section><p class="block-title">' + escapeHtml(block.heading || 'Repository files') + ' (' + files.length + ')</p>' +
      (files.length ? '<div class="file-list">' + files.map(function (file) {
        return '<div class="resource"><span class="status-dot status-' + escapeAttribute(file.status) + '"></span>' +
          '<span class="file-path">' + escapeHtml(file.path) + '</span>' +
          '<span class="status-chip">' + escapeHtml(file.status) + '</span></div>';
      }).join('') + '</div>' : '<p class="field-hint">No repository files need changes.</p>') +
      '</section>';
  }

  function promptHeader(prompt, kindLabel) {
    return '<div class="prompt-head"><div>' +
      (prompt.eyebrow ? '<p class="eyebrow">' + escapeHtml(prompt.eyebrow) + '</p>' : '') +
      '<h1>' + escapeHtml(prompt.title || 'Setup') + '</h1>' +
      (prompt.message ? '<p class="lede">' + escapeHtml(prompt.message) + '</p>' : '') +
      '</div>' +
      (kindLabel ? '<span class="prompt-kind">' + escapeHtml(kindLabel) + '</span>' : '') +
      '</div>' + renderGuidance(prompt);
  }

  function promptFooter(prompt, primaryHtml) {
    var buttons = primaryHtml || '';
    if (prompt.allowBack) {
      buttons += '<button class="btn btn-ghost" type="button" data-back>Back</button>';
    } else if (prompt.cancelLabel) {
      buttons += '<button class="btn btn-danger" type="button" data-cancel>' + escapeHtml(prompt.cancelLabel) + '</button>';
    }
    if (!buttons) {
      return '';
    }
    return '<div class="prompt-actions">' + buttons + '</div>';
  }

  function renderPrompt(prompt, state, wizard) {
    var html = '';
    if (wizard && prompt.kind !== 'complete') {
      html += renderWizardTrail(wizard);
    }
    html += renderPromptContext(prompt);
    switch (prompt.kind) {
      case 'menu':
        html += renderMenu(prompt);
        break;
      case 'confirm':
        html += renderConfirm(prompt);
        break;
      case 'yesno':
        html += renderYesNo(prompt);
        break;
      case 'text':
      case 'secret':
        html += renderTextPrompt(prompt);
        break;
      case 'notice':
        html += renderNoticePrompt(prompt);
        break;
      case 'error':
        html += renderErrorPrompt(prompt);
        break;
      case 'review':
        html += renderReview(prompt);
        break;
      case 'diff':
        html += renderDiff(prompt);
        break;
      case 'device':
        html += renderDevicePrompt(prompt);
        break;
      case 'complete':
        html += renderComplete(prompt);
        break;
      case 'stopped':
        html += renderStopped(prompt);
        break;
      default:
        html += '<section class="card">' + promptHeader(prompt, '') + '</section>';
        break;
    }
    stage.innerHTML = '<div class="stage-inner">' + html + '</div>';
    focusStage(prompt);
  }

  function renderPromptContext(prompt) {
    // Summary tables queued before a prompt, such as the current branch or environment
    // configuration the console prints above its edit menu. Review renders its own.
    if (prompt.kind === 'review') {
      return '';
    }
    var body = renderBlocks(prompt.blocks);
    if (!body) {
      return '';
    }
    return '<section class="card context-card">' + body + '</section>';
  }

  function renderWizardTrail(wizard) {
    var progress = wizard.progress || {};
    return '<div class="card" style="padding:16px 20px"><div style="display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap">' +
      '<div><p class="eyebrow" style="margin-bottom:3px">Guided setup</p><strong>' + escapeHtml(wizard.title || 'Setup') + '</strong></div>' +
      '<div class="wizard-progress" style="max-width:300px"><div class="wizard-progress-label"><span>' + escapeHtml(String(progress.completed || 0)) + ' of ' + escapeHtml(String(progress.total || 0)) + ' steps complete</span><span>' + escapeHtml(String(Math.round(progress.percent || 0))) + '%</span></div>' +
      '<div class="progress-track"><div class="progress-fill" style="width:' + escapeAttribute(Math.max(0, Math.min(100, progress.percent || 0))) + '%"></div></div></div>' +
      '</div></div>';
  }

  function renderMenu(prompt) {
    var items = asArray(prompt.items);
    var actionFirst = !!prompt.actionFirst;
    var normal = [];
    var actions = [];
    items.forEach(function (item, index) {
      var entry = { item: item, index: index };
      if (item.action) {
        actions.push(entry);
      } else {
        normal.push(entry);
      }
    });

    function choiceHtml(entry) {
      var item = entry.item;
      var classes = 'choice';
      if (item.action) {
        classes += ' is-action';
      }
      if (item.dimmed) {
        classes += ' is-dimmed';
      }
      return '<button class="' + classes + '" type="button" role="option" data-choice="' + entry.index + '" aria-selected="false">' +
        '<span class="choice-marker" aria-hidden="true"></span>' +
        '<span class="choice-text">' + escapeHtml(item.label) +
        (item.hint ? '<span class="choice-hint">' + escapeHtml(item.hint) + '</span>' : '') +
        '</span></button>';
    }

    var body = '';
    if (actionFirst && actions.length) {
      body += actions.map(choiceHtml).join('');
      if (normal.length) {
        body += '<div class="choice-separator">' + escapeHtml(prompt.actionSectionTitle || 'Setup steps') + '</div>';
      }
    }
    body += normal.map(choiceHtml).join('');
    if (!actionFirst && actions.length) {
      if (normal.length) {
        body += '<div class="choice-separator">' + escapeHtml(prompt.actionSectionTitle || 'Actions') + '</div>';
      }
      body += actions.map(choiceHtml).join('');
    }

    var filter = items.length > 5
      ? '<div class="field search-field"><label for="choice-filter">Search options</label>' +
        '<div class="search-control">' + icon('search', 'search-icon') +
        '<input id="choice-filter" class="field-input search-input" type="search" autocomplete="off" placeholder="Type to narrow the list" aria-describedby="choice-count" />' +
        '<button class="search-clear" type="button" data-clear-filter hidden>Clear</button></div>' +
        '<span class="field-hint" id="choice-count">' + items.length + ' options</span></div>'
      : '';

    return '<section class="card">' + promptHeader(prompt, items.length > 5 ? 'Searchable list' : 'Choose one') + filter +
      '<div class="choice-list" id="choice-list" role="listbox" aria-label="' + escapeAttribute(prompt.title || 'Options') + '">' + body + '</div>' +
      '<p class="field-hint no-results" id="choice-empty" hidden>No matching options. Try a different search.</p>' +
      promptFooter(prompt, '') + '</section>';
  }

  function renderConfirm(prompt) {
    var body = '<div class="choice-list"><button class="choice is-action" type="button" data-confirm="yes">' +
      '<span class="choice-marker" aria-hidden="true"></span><span class="choice-text">' + escapeHtml(prompt.confirmLabel || 'Continue') + '</span></button>' +
      '<button class="choice" type="button" data-confirm="no"><span class="choice-marker" aria-hidden="true"></span>' +
      '<span class="choice-text">' + escapeHtml(prompt.declineLabel || 'No') + '</span></button></div>';
    return '<section class="card">' + promptHeader(prompt, 'Confirmation') + body +
      (prompt.allowBack ? '<div class="prompt-actions"><button class="btn btn-ghost" type="button" data-back>Back</button></div>' : '') + '</section>';
  }

  function renderYesNo(prompt) {
    var yesClass = prompt.defaultYes ? 'btn btn-primary' : 'btn btn-secondary';
    var noClass = prompt.defaultYes ? 'btn btn-secondary' : 'btn btn-primary';
    return '<section class="card">' + promptHeader(prompt, 'Yes or no') +
      '<div class="segmented"><button class="' + yesClass + '" type="button" data-confirm="yes">Yes</button>' +
      '<button class="' + noClass + '" type="button" data-confirm="no">No</button></div>' +
      promptFooter(prompt, '') + '</section>';
  }

  function renderTextPrompt(prompt) {
    var isSecret = prompt.kind === 'secret';
    var defaultValue = !isSecret && prompt.default ? String(prompt.default) : '';
    var inputAttributes = isSecret
      ? 'type="password" autocomplete="off" spellcheck="false"'
      : 'type="text" autocomplete="off" spellcheck="false"';
    var inputValue = defaultValue ? ' value="' + escapeAttribute(defaultValue) + '"' : '';
    var valueHint = '';
    var resetButton = '';
    if (defaultValue) {
      valueHint = '<span class="field-hint">Default: <strong>' + escapeHtml(defaultValue) + '</strong>.</span>';
      resetButton = '<button class="btn btn-ghost" type="button" data-reset-default disabled title="Reset to the default value">Reset to default</button>';
    } else if (prompt.allowEmpty) {
      valueHint = '<span class="field-hint">This value is optional.</span>';
    }
    var errorHtml = prompt.error ? '<div class="field-error">' + escapeHtml(prompt.error) + '</div>' : '';
    var revealButton = isSecret
      ? '<button class="btn btn-ghost" type="button" data-reveal aria-label="Show or hide the value">Show</button>'
      : '';
    return '<section class="card">' + promptHeader(prompt, isSecret ? 'Private input' : 'Input') +
      '<form data-text-form>' +
      '<div class="field"><label for="prompt-value">' + escapeHtml(prompt.valueLabel || prompt.title || 'Value') + '</label>' +
      '<div class="field-control"><input id="prompt-value" class="field-input" ' + inputAttributes + inputValue + ' />' + resetButton + revealButton + '</div>' +
      valueHint + errorHtml + '</div>' +
      '<div class="prompt-actions"><button class="btn btn-primary" type="submit">Continue</button>' +
      (prompt.allowBack ? '<button class="btn btn-ghost" type="button" data-back>Back</button>' : '') +
      (!prompt.allowBack && prompt.cancelLabel ? '<button class="btn btn-danger" type="button" data-cancel>' + escapeHtml(prompt.cancelLabel) + '</button>' : '') +
      '</div></form></section>';
  }

  function renderNoticePrompt(prompt) {
    return '<section class="card">' + promptHeader(prompt, 'Notice') +
      (prompt.message ? '' : '<p class="lede">' + escapeHtml(prompt.notice || '') + '</p>') +
      '<div class="prompt-actions"><button class="btn btn-primary" type="button" data-continue>' + escapeHtml(prompt.continueLabel || 'Continue') + '</button>' +
      (prompt.allowBack ? '<button class="btn btn-ghost" type="button" data-back>Back</button>' : '') + '</div></section>';
  }

  function renderErrorPrompt(prompt) {
    var options = asArray(prompt.options);
    if (!options.length) {
      options = [{ id: 'abort', label: 'Abort setup', kind: 'danger' }];
    }
    return '<section class="card"><p class="eyebrow">Setup error</p><h1>' + escapeHtml(prompt.title || 'Something went wrong') + '</h1>' +
      (prompt.message ? '<p class="lede">' + escapeHtml(prompt.message) + '</p>' : '') +
      '<pre class="error-details">' + escapeHtml(asArray(prompt.details).join('\n')) + '</pre>' +
      '<div class="prompt-actions">' + options.map(function (option) {
        return '<button class="btn ' + (option.kind === 'primary' ? 'btn-primary' : option.kind === 'danger' ? 'btn-danger' : 'btn-ghost') + '" type="button" data-error-option="' + escapeAttribute(option.id) + '">' + escapeHtml(option.label) + '</button>';
      }).join('') + '</div></section>';
  }

  function renderReview(prompt) {
    var blocks = asArray(prompt.blocks);
    var files = asArray(prompt.files);
    var body = blocks.map(function (block) {
      if (block.type === 'files' && files.length) {
        return '';
      }
      return renderBlock(block);
    }).join('');
    if (files.length) {
      body += '<section><p class="block-title">Repository files (' + files.length + ')</p><div class="file-list">' +
        files.map(function (file, index) {
          return '<button class="file-row" type="button" data-file-index="' + index + '">' +
            '<span class="status-dot status-' + escapeAttribute(file.status) + '"></span>' +
            '<span class="file-path">' + escapeHtml(file.path) + '</span>' +
            '<span class="status-chip">' + escapeHtml(file.status) + '</span>' +
            '<span class="next-link-arrow" aria-hidden="true">&rsaquo;</span></button>';
        }).join('') + '</div></section>';
    }
    return '<section class="card">' + promptHeader(prompt, 'Review') + '<div class="blocks">' + body + '</div>' +
      '<div class="prompt-actions"><button class="btn btn-primary" type="button" data-review-done>' + escapeHtml(prompt.doneLabel || 'Done reviewing') + '</button></div></section>';
  }

  function renderDiff(prompt) {
    var rows = asArray(prompt.rows);
    var file = prompt.file || {};
    var rowsHtml = rows.map(function (row) {
      var type = String(row.type || 'Context').toLowerCase();
      return '<div class="diff-row is-' + escapeAttribute(type) + '">' +
        '<div class="diff-cell">' + escapeHtml(row.left) + '</div>' +
        '<div class="diff-cell">' + escapeHtml(row.right) + '</div>' +
        '</div>';
    }).join('');
    return '<section class="card"><div class="diff-head"><div><p class="eyebrow">File diff</p><h1>' + escapeHtml(file.status || 'Changed') + '</h1>' +
      '<p class="diff-file">' + escapeHtml(file.path || '') + '</p></div>' +
      '<div class="diff-legend"><span>BEFORE</span><span>AFTER</span></div></div>' +
      (prompt.summary ? '<p class="lede">' + escapeHtml(prompt.summary) + '</p>' : '') +
      '<div class="diff-scroll"><div class="diff-table"><div class="diff-header"><span>Before</span><span>After</span></div>' + rowsHtml + '</div></div>' +
      '<div class="prompt-actions"><button class="btn btn-primary" type="button" data-diff-close>Back to review</button></div></section>';
  }

  function renderDevicePrompt(prompt) {
    return '<section class="card">' + promptHeader(prompt, 'Sign-in') +
      '<div class="thinking"><span class="spinner" aria-hidden="true"></span><span>' + escapeHtml(prompt.message || 'Complete sign-in in your browser.') + '</span></div>' +
      '<p class="lede" style="margin-top:16px">The verification details appear at the top of this page. Setup continues automatically after sign-in.</p></section>';
  }

  function renderComplete(prompt) {
    var summary = asArray(prompt.summary);
    var nextSteps = asArray(prompt.nextSteps);
    var access = prompt.access || {};
    var html = '<section class="card"><div class="complete-hero"><div class="complete-tick" aria-hidden="true">' + icon('check') + '</div>' +
      '<p class="eyebrow">Setup finished</p><h1>' + escapeHtml(prompt.heading || 'Setup completed successfully') + '</h1>' +
      (prompt.message ? '<p class="lede" style="margin-left:auto;margin-right:auto">' + escapeHtml(prompt.message) + '</p>' : '') + '</div>';
    if (summary.length) {
      html += '<dl class="summary-grid">' + summary.map(function (entry) {
        return '<div class="summary-item"><dt class="summary-label">' + escapeHtml(entry.label) + '</dt><dd class="summary-value">' + escapeHtml(entry.value) + '</dd></div>';
      }).join('') + '</dl>';
    }
    if (access.url) {
      html += '<div class="prompt-actions" style="justify-content:center"><a class="btn btn-primary" href="' + escapeAttribute(safeUrl(access.url)) + '" target="_blank" rel="noreferrer noopener">' + escapeHtml(access.label || 'Open') + '</a></div>';
    }
    if (nextSteps.length) {
      html += '<section style="margin-top:28px"><p class="block-title">Next steps</p><div class="next-links">' + nextSteps.map(function (step) {
        return '<a class="next-link" href="' + escapeAttribute(safeUrl(step.url)) + '" target="_blank" rel="noreferrer noopener"><span>' + escapeHtml(step.label) + '</span><span class="next-link-arrow" aria-hidden="true">&rarr;</span></a>';
      }).join('') + '</div></section>';
    }
    html += '<p class="finished-note">You can close this tab when you are ready. The setup window can also be closed.</p></section>';
    return html;
  }

  function renderStopped(prompt) {
    return '<section class="card"><div class="complete-hero"><div class="complete-tick" style="background:var(--warning-background);color:var(--warning-foreground)" aria-hidden="true">' + icon('dismiss') + '</div>' +
      '<p class="eyebrow">Setup stopped</p><h1>' + escapeHtml(prompt.title || 'Setup stopped') + '</h1>' +
      (prompt.message ? '<p class="lede" style="margin-left:auto;margin-right:auto">' + escapeHtml(prompt.message) + '</p>' : '') +
      '</div><p class="finished-note">Nothing was applied by this screen. Review the setup window for details.</p></section>';
  }

  function renderBlock(block) {
    switch (block.type) {
      case 'metrics': return renderMetrics(block);
      case 'table': return renderTable(block);
      case 'keyvalue': return renderKeyValue(block);
      case 'resources': return renderResources(block);
      case 'files': return renderFileSummary(block);
      case 'file': return '<section><p class="block-title">' + escapeHtml(block.heading || block.path) + '</p><pre class="file-preview">' + escapeHtml(block.content || '') + '</pre></section>';
      default: return '';
    }
  }

  // Sub-items arrive flat with a Depth so the console menu can reuse them. Build
  // the same tree here, then nest each branch's DEV, BUILD and deployment rows
  // inside its group instead of rendering every target as a separate card.
  function buildSubItemTree(subItems) {
    var roots = [];
    var stack = [];
    asArray(subItems).forEach(function (subItem) {
      var depth = Math.max(1, Number(subItem.depth) || 1);
      var node = { item: subItem, depth: depth, children: [] };
      while (stack.length && stack[stack.length - 1].depth >= depth) {
        stack.pop();
      }
      if (stack.length) {
        stack[stack.length - 1].node.children.push(node);
      } else {
        roots.push(node);
      }
      stack.push({ depth: depth, node: node });
    });
    return roots;
  }

  function subItemParts(label) {
    var match = /^(DEV|BUILD validation|Deployment)\s*:\s*([\s\S]*)$/.exec(String(label || ''));
    if (!match) {
      return { kind: '', kindClass: '', primary: String(label || ''), detail: '' };
    }
    var parts = match[2].split(/\s+-\s+/);
    return {
      kind: match[1] === 'BUILD validation' ? 'BUILD' : match[1] === 'Deployment' ? 'DEPLOYMENT' : 'DEV',
      kindLabel: match[1],
      kindClass: match[1] === 'DEV' ? 'is-dev' : match[1] === 'BUILD validation' ? 'is-build' : 'is-deployment',
      primary: parts.shift() || '',
      detail: parts.join(' \u00b7 ')
    };
  }

  function renderSubItemNode(node, parentDepth, stepIndex) {
    var item = node.item;
    var parts = subItemParts(item.label);
    var depth = Math.max(1, Number(item.depth) || 1);
    var extraIndent = Math.max(0, depth - (parentDepth + 1));
    var hasChildren = node.children.length > 0;
    var classes = 'subitem-row' + (hasChildren ? ' is-parent' : ' is-child');
    var style = extraIndent ? ' style="padding-left:' + (8 + extraIndent * 14) + 'px"' : '';
    var lead = parts.kindClass
      ? '<span class="subitem-kind ' + parts.kindClass + '" aria-label="' + escapeAttribute(parts.kindLabel) + '">' + escapeHtml(parts.kind) + '</span>'
      : '<span class="subitem-branch-icon" aria-hidden="true">' + icon('branch') + '</span>';
    var count = hasChildren
      ? '<span class="subitem-count">' + node.children.length + (node.children.length === 1 ? ' target' : ' targets') + '</span>'
      : '';
    return '<li class="subitem-node' + (hasChildren ? ' has-children' : '') + '">' +
      '<button class="' + classes + '" type="button" data-wizard-entry="' + escapeAttribute(item.id) + '" data-wizard-step="' + stepIndex + '" title="' + escapeAttribute(item.label) + '"' + style + '>' +
      lead + '<span class="subitem-text"><span class="subitem-primary">' + escapeHtml(parts.primary) + '</span>' +
      (parts.detail ? '<span class="subitem-detail">' + escapeHtml(parts.detail) + '</span>' : '') + '</span>' +
      count + '<span class="subitem-chevron" aria-hidden="true">' + icon('chevron') + '</span></button>' +
      (hasChildren ? renderSubItemTree(node.children, depth, stepIndex) : '') + '</li>';
  }

  function renderSubItemTree(nodes, parentDepth, stepIndex) {
    var className = parentDepth === 0 ? 'subitem-tree' : 'subitem-children';
    return '<ul class="' + className + '">' + nodes.map(function (node) {
      return renderSubItemNode(node, parentDepth, stepIndex);
    }).join('') + '</ul>';
  }

  function renderWizard(wizard, state) {
    var steps = asArray(wizard.steps);
    var actions = asArray(wizard.actions);
    var progress = wizard.progress || {};
    var cards = steps.map(function (step) {
      var classes = 'step-card';
      if (step.complete) { classes += ' is-complete'; }
      if (step.active) { classes += ' is-active'; }
      if (step.status === 'locked') { classes += ' is-locked'; }
      if (step.status === 'blocked') { classes += ' is-blocked'; }
      var subitems = asArray(step.subItems);
      if (subitems.length) { classes += ' has-subitems'; }
      var subitemTree = subitems.length
        ? '<div class="step-subitems">' + renderSubItemTree(buildSubItemTree(subitems), 0, step.index) + '</div>'
        : '';
      return '<article class="' + classes + '" aria-labelledby="step-title-' + step.index + '">' +
        '<button class="step-card-main" type="button" data-wizard-step="' + step.index + '">' +
        '<span class="step-index">' + (step.complete ? icon('check') : escapeHtml(String(step.index + 1).padStart(2, '0'))) + '</span>' +
        '<span class="step-main"><span class="step-title-row"><span class="step-title" id="step-title-' + step.index + '">' + escapeHtml(step.name) + '</span>' +
        '<span class="step-badge">' + escapeHtml(step.statusLabel) + '</span></span>' +
        (step.summary ? '<span class="step-summary">' + escapeHtml(step.summary) + '</span>' : '') +
        '</span></button>' + subitemTree + '</article>';
    }).join('');

    var actionButtons = actions.map(function (action) {
      var classes = 'btn ' + (action.kind === 'primary' ? 'btn-primary' : action.kind === 'danger' ? 'btn-danger' : action.kind === 'secondary' ? 'btn-secondary' : 'btn-ghost');
      var disabled = action.enabled ? '' : ' disabled aria-disabled="true"';
      return '<button class="' + classes + '" type="button" data-wizard-action="' + escapeAttribute(action.id) + '"' + disabled + '>' + escapeHtml(action.label) + '</button>';
    }).join('');

    var reasons = actions.filter(function (action) { return !action.enabled && action.reason; }).map(function (action) {
      return '<p class="action-reason">' + escapeHtml(action.reason) + '</p>';
    }).join('');

    var dashboardLink = state && state.app ? '' : '';
    stage.innerHTML = '<div class="stage-inner"><section class="card"><div class="wizard-head"><div><p class="eyebrow">Guided setup</p><h1>' + escapeHtml(wizard.title) + '</h1>' +
      '<p class="lede">Pick any unlocked step card. Completed cards stay editable, and the apply action unlocks when every step is complete.</p></div>' +
      '<div class="wizard-progress"><div class="wizard-progress-label"><span>' + escapeHtml(String(progress.completed || 0)) + ' of ' + escapeHtml(String(progress.total || 0)) + ' steps</span><span>' + escapeHtml(String(Math.round(progress.percent || 0))) + '%</span></div>' +
      '<div class="progress-track"><div class="progress-fill" style="width:' + escapeAttribute(Math.max(0, Math.min(100, progress.percent || 0))) + '%"></div></div></div></div>' +
      (wizard.notice ? '<div class="notice' + (wizard.noticeTone === 'error' ? ' is-error' : '') + '">' + escapeHtml(wizard.notice) + '</div>' : '') +
      '<div class="step-grid">' + cards + '</div>' + dashboardLink +
      '<div class="action-bar">' + actionButtons + '</div>' + reasons + '</section></div>';
    currentRenderSignature = 'wizard:' + JSON.stringify(wizard);
    var firstCard = stage.querySelector('.step-card-main');
    if (firstCard) {
      firstCard.focus({ preventScroll: true });
    }
  }

  function renderWorking(state) {
    // The working card owns the progress surface; never stack the click-time pill on it.
    hideBusy();
    var message = state.busy || 'Working through the next setup action...';
    stage.innerHTML = '<div class="stage-inner stage-inner-working"><section class="card hero-card working-card">' +
      '<p class="eyebrow">' + escapeHtml(state.app || 'ALM4Dataverse setup') + '</p>' +
      '<h1>' + escapeHtml(state.section || 'Preparing setup') + '</h1>' +
      '<p class="lede">' + escapeHtml(message) + '</p>' +
      '<div class="thinking working-thinking">' +
      '<svg class="busy-spinner" viewBox="0 0 48 48" aria-hidden="true">' +
      '<circle class="busy-spinner-track" cx="24" cy="24" r="19"></circle>' +
      '<circle class="busy-spinner-arc" cx="24" cy="24" r="19"></circle>' +
      '</svg><span>This page updates automatically.</span></div>' +
      '<div class="working-output"><div class="working-output-head"><span>Console output</span><span>Live</span></div>' +
      '<div class="working-output-log" id="working-output-log" role="log" aria-live="polite"></div></div>' +
      '</section></div>';
  }

  function updateWorkingOutput(entries) {
    var log = document.getElementById('working-output-log');
    if (!log) {
      return;
    }
    entries = asArray(entries).slice(-14);
    if (!entries.length) {
      log.innerHTML = '<div class="working-output-empty">Waiting for console output...</div>';
      return;
    }
    var initialized = log.getAttribute('data-initialized') === 'true';
    var wasNearBottom = log.scrollTop + log.clientHeight >= log.scrollHeight - 24;
    log.innerHTML = entries.map(function (entry) {
      var tone = entry.tone || 'info';
      return '<div class="log-entry is-' + escapeHtml(tone) + '">' +
        '<span class="log-time">' + escapeHtml(entry.time || '') + '</span>' +
        '<span class="log-text">' + escapeHtml(entry.text || '') + '</span>' +
        '</div>';
    }).join('');
    if (!initialized || wasNearBottom) {
      log.scrollTop = log.scrollHeight;
    }
    log.setAttribute('data-initialized', 'true');
  }

  function focusStage(prompt) {
    var element = null;
    if (prompt.kind === 'text' || prompt.kind === 'secret') {
      element = stage.querySelector('#prompt-value');
    } else if (prompt.kind === 'menu') {
      element = stage.querySelector('#choice-filter') || stage.querySelector('.choice');
    } else if (prompt.kind === 'review') {
      element = stage.querySelector('[data-review-done]');
    } else if (prompt.kind === 'diff') {
      element = stage.querySelector('[data-diff-close]');
    } else if (prompt.kind === 'error') {
      element = stage.querySelector('[data-error-option]');
    } else if (prompt.kind === 'complete') {
      element = stage.querySelector('.btn-primary');
      if (!completionAcknowledged) {
        completionAcknowledged = true;
        window.setTimeout(function () {
          postAction({ action: 'complete', operation: 'ack' }, true);
        }, 650);
      }
    } else if (prompt.kind === 'stopped') {
      if (!completionAcknowledged) {
        completionAcknowledged = true;
        window.setTimeout(function () {
          postAction({ action: 'stopped', operation: 'ack' }, true);
        }, 500);
      }
    }
    if (element && typeof element.focus === 'function') {
      element.focus({ preventScroll: true });
      if (prompt.kind === 'text' && element.value && typeof element.select === 'function') {
        element.select();
      }
    }
  }

  function submitChoice(index) {
    postAction({ action: 'choose', value: index });
  }

  function wireEvents() {
    stage.addEventListener('click', function (event) {
      var target = event.target.closest('button, a');
      if (!target) {
        return;
      }
      if (target.hasAttribute('data-clear-filter')) {
        var filterField = stage.querySelector('#choice-filter');
        if (filterField) {
          filterField.value = '';
          filterField.dispatchEvent(new Event('input', { bubbles: true }));
          filterField.focus();
        }
        return;
      }
      if (target.hasAttribute('data-choice')) {
        submitChoice(Number(target.getAttribute('data-choice')));
        return;
      }
      if (target.hasAttribute('data-wizard-step')) {
        var operation = target.hasAttribute('data-wizard-entry') ? 'selectEntry' : 'selectStep';
        var payload = { action: 'wizard', operation: operation, index: Number(target.getAttribute('data-wizard-step')) };
        if (operation === 'selectEntry') {
          payload.entryId = target.getAttribute('data-wizard-entry');
        }
        postAction(payload);
        return;
      }
      if (target.hasAttribute('data-wizard-action')) {
        postAction({ action: 'wizard', operation: target.getAttribute('data-wizard-action') });
        return;
      }
      if (target.hasAttribute('data-confirm')) {
        postAction({ action: target.getAttribute('data-confirm') === 'yes' ? 'yes' : 'no' });
        return;
      }
      if (target.hasAttribute('data-continue')) {
        postAction({ action: 'continue' });
        return;
      }
      if (target.hasAttribute('data-back')) {
        postAction({ action: 'back' });
        return;
      }
      if (target.hasAttribute('data-cancel')) {
        postAction({ action: 'cancel' });
        return;
      }
      if (target.hasAttribute('data-reveal')) {
        var field = stage.querySelector('#prompt-value');
        if (field) {
          var reveal = field.type === 'password';
          field.type = reveal ? 'text' : 'password';
          target.textContent = reveal ? 'Hide' : 'Show';
        }
        return;
      }
      if (target.hasAttribute('data-reset-default')) {
        var resetField = stage.querySelector('#prompt-value');
        if (resetField) {
          resetField.value = resetField.defaultValue;
          resetField.dispatchEvent(new Event('input', { bubbles: true }));
          resetField.focus();
        }
        return;
      }
      if (target.hasAttribute('data-review-done')) {
        postAction({ action: 'review', operation: 'done' });
        return;
      }
      if (target.hasAttribute('data-file-index')) {
        postAction({ action: 'review', operation: 'openFile', index: Number(target.getAttribute('data-file-index')) });
        return;
      }
      if (target.hasAttribute('data-diff-close')) {
        postAction({ action: 'diff', operation: 'close' });
        return;
      }
      if (target.hasAttribute('data-error-option')) {
        postAction({ action: 'error', value: target.getAttribute('data-error-option') });
      }
    });

    stage.addEventListener('input', function (event) {
      if (!event.target || event.target.id !== 'choice-filter') {
        return;
      }
      var filterText = event.target.value.trim().toLowerCase();
      var choices = Array.prototype.slice.call(stage.querySelectorAll('.choice'));
      var visibleCount = 0;
      choices.forEach(function (choice) {
        var matches = !filterText || choice.textContent.toLowerCase().indexOf(filterText) >= 0;
        choice.hidden = !matches;
        if (matches) {
          visibleCount++;
        }
      });
      var countLabel = stage.querySelector('#choice-count');
      if (countLabel) {
        countLabel.textContent = filterText ? visibleCount + ' of ' + choices.length + ' options' : choices.length + ' options';
      }
      var clearButton = stage.querySelector('[data-clear-filter]');
      if (clearButton) {
        clearButton.hidden = !filterText;
      }

      var choiceList = stage.querySelector('#choice-list');
      var noResults = stage.querySelector('#choice-empty');
      if (noResults) {
        noResults.hidden = visibleCount > 0 || !filterText;
      }
      if (choiceList) {
        var children = Array.prototype.slice.call(choiceList.children);
        children.forEach(function (child, childIndex) {
          if (!child.classList.contains('choice-separator')) {
            return;
          }
          var hasVisibleChoice = false;
          for (var index = childIndex + 1; index < children.length; index++) {
            if (children[index].classList.contains('choice-separator')) {
              break;
            }
            if (children[index].classList.contains('choice') && !children[index].hidden) {
              hasVisibleChoice = true;
              break;
            }
          }
          child.hidden = !hasVisibleChoice;
        });
      }
    });

    stage.addEventListener('input', function (event) {
      if (!event.target || event.target.id !== 'prompt-value') {
        return;
      }
      var reset = stage.querySelector('[data-reset-default]');
      if (reset) {
        reset.disabled = event.target.value === event.target.defaultValue;
      }
    });

    stage.addEventListener('submit', function (event) {
      if (!event.target.matches('[data-text-form]')) {
        return;
      }
      event.preventDefault();
      var field = stage.querySelector('#prompt-value');
      postAction({ action: 'submit', value: field ? field.value : '' });
    });

    document.addEventListener('keydown', function (event) {
      var tag = (event.target && event.target.tagName) || '';
      var isTyping = tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
      if (event.key === 'Escape' && event.target && event.target.id === 'choice-filter' && event.target.value) {
        event.preventDefault();
        var clearFilter = stage.querySelector('[data-clear-filter]');
        if (clearFilter) {
          clearFilter.click();
        }
        return;
      }
      if (event.key === 'Escape') {
        var back = stage.querySelector('[data-back]');
        var cancel = stage.querySelector('[data-cancel]');
        var diffClose = stage.querySelector('[data-diff-close]');
        if (diffClose) {
          event.preventDefault();
          diffClose.click();
        } else if (back) {
          event.preventDefault();
          back.click();
        } else if (cancel) {
          event.preventDefault();
          cancel.click();
        }
        return;
      }
      if (event.target && event.target.id === 'choice-filter') {
        var firstVisibleChoice = stage.querySelector('.choice:not(.is-dimmed):not([hidden])');
        if ((event.key === 'ArrowDown' || event.key === 'Enter') && firstVisibleChoice) {
          event.preventDefault();
          if (event.key === 'Enter') {
            firstVisibleChoice.click();
          } else {
            firstVisibleChoice.focus();
          }
        }
        return;
      }
      if (isTyping) {
        return;
      }
      var choices = Array.prototype.slice.call(stage.querySelectorAll('.choice:not(.is-dimmed):not([hidden]), .step-card-main, .subitem-row'));
      if (!choices.length) {
        return;
      }
      var currentIndex = choices.indexOf(document.activeElement);
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        var nextIndex = event.key === 'ArrowDown' ? currentIndex + 1 : currentIndex - 1;
        if (nextIndex < 0) { nextIndex = choices.length - 1; }
        if (nextIndex >= choices.length) { nextIndex = 0; }
        choices[nextIndex].focus();
      } else if (event.key === 'Enter' && currentIndex < 0) {
        event.preventDefault();
        choices[0].click();
      }
    });

    activityFab.addEventListener('click', function () {
      var open = activityDrawer.classList.toggle('is-open');
      activityFab.setAttribute('aria-expanded', open ? 'true' : 'false');
      if (open) {
        activityLog.scrollTop = activityLog.scrollHeight;
      }
    });

    activityClose.addEventListener('click', function () {
      activityDrawer.classList.remove('is-open');
      activityFab.setAttribute('aria-expanded', 'false');
    });

    themeToggle.addEventListener('click', function () {
      var nextTheme = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
      applyTheme(nextTheme);
      try {
        localStorage.setItem('alm4dataverse.setup.theme', nextTheme);
      } catch (error) {
        // Local storage can be unavailable in hardened browsers; the toggle still works.
      }
    });

    deviceCopy.addEventListener('click', function () {
      var text = deviceCopy.getAttribute('data-code') || deviceMessage.textContent || '';
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          showToast('Device code copied.');
        }, function () {
          showToast('Select the text above to copy it.');
        });
      } else {
        showToast('Select the text above to copy it.');
      }
    });
  }

  var initialTheme = 'light';
  try {
    if (localStorage.getItem('alm4dataverse.setup.theme') === 'dark') {
      initialTheme = 'dark';
    }
  } catch (error) {
    // Default to light when local storage is unavailable.
  }
  applyTheme(initialTheme);

  wireEvents();
  tick();
})();

'@

$script:SetupWebLogoBase64 = @'
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
OSYm5tXx48dfc+DAgcjRo0ffMmjQIJ1kdfz48Z6JiYl3A0BgYODOsWPHrrrnnnv+HhERUa6t16lTp9K777573dixY1eNHTt2VYcOHbYDdptgq1atxNtuu22f
n5+fzWg0YsyYMT+NHTv25l9++aX7Qw891O2ee+5Z7+fnp76IVlRUUEZGxnBN32u7deum20TPnz9/7XPPPaeTUnJycm4tL3dMSxAEtG/fXpXkz549+8zu3bt1
asMBAwYkjR49+p6DBw/2GDt2bPcJEybEaYns6NGjUcePH38a9SAhIaGV1WpFhw4digYPHnxo0KBBR4cMGZIVGhoaK89rVF5ensqgvXv3Pjdq1KgB+/fv73Hf
ffdF3XPPPa8PHDjw/M0337zu448//kDb94ULF8Q//vhDJUzGGMaNG/fj7bff3ufXX3/9v+HDh18/ZMiQI8p9zjlOnTo1ZPbs2VelgVDHa2zFkZte8C0tLB1k
s0mqOzGzSylcJQ2B7G7IAuOqBEMa1Rizt3FIK8SZvW4hQ+34REtsQcMzcY/4aZYKUwvpbuI2O8E4uxlrfMhUqPdcXYS5YifRSDNKN1xTR9eP0z3uaOI0nt3Z
DJwDNunHz6IX7dSuZfJ28UYIbBnXzFz9xx0/5X4aeCPWO7kp8+AgIzcatsTEzdO91ZReKlwDSUpzJRjFZ4JD9zz0qsi/jdv6fJv65+Me6enpU9PT01Wxn4gQ
FBSk/uJbLJaKtm3b/qFtc+nSJd+MjIyHr2S8K0X79u23tGvXTrV8W61WZGVlDVKus7KyHsrMzPRWrjt37nx81apVCY3tn4jot6rfPtqLvde1Qqvq62zXrVzz
8ppGt78aMMZcCIxzLgDArFmzqj/55JM5I0eOHDJ+/PhtN9100+KPP/54nsViPxZ87dq1Rzt37vyF/KIIACgtLaWCgoIBALBly5Z/xMfHz+7Zs+dio9Go00qY
TKbaXr16LYyPj58dHx8/e8uWLaq95b333vvpxhtvvHnChAkvT5gwYWf//v3vWLPG/jxmzZpVvWXLlhk9e/bUqRxLS0s7KZ+XLFmS0aFDB11mhvT0dN+MjAzV
y1IURUNeXp7uxaZ79+65nTp1UgOlL126NK6yslL9YwoKCqrq1auX5f33398JABaLpSYqKmpajx490pU61dXVyM3N1bnVu0Pfvn3PjBw5cvy+fftu2L9/f/+h
Q4f2XLp0aTIAVFVV6TIt1NbWGqqrq8MA4MUXXyzdvHnz3JEjR/5ty5YtL2nrzZs3LyIlJUXn9NKvX79T1157bczKlSszAGD16tXnu3Xr9r63t/rritTU1DaX
L1/WeaBeKRpt0G/t7TUgszDHR307Z8ohknIF++5HYOCOt3hS93R7RjDSbnByfeK8tnbuoXmx5692MR/ebKmKiZt9j8mr1ZcSYaRdtJCcIuUdcojD9s/liBtH
dmR1WeopmWoj2SPXQI3wAAAgAElEQVQXaJQayh0cLr0cVutSrTrM7urd5j1OZFTnrJFZHCo2wFkocQ8tmSpFSp/UhpmMawBMUKp8O+ud6knbxHeI+Eo1/kjP
uvoCXfYBJvh4tRgC4MvGzEyBKIosOzt7gLYsPDy8LDw8/GNtWVBQ0CGj0TiuttaxB16+fHmg3WPiTziv2w3WrFmz68SJEydycnL6K2WXLl26bu7cuZ1ff/31
84MGDVI3EyJCu3btDjSl//sX3r90G982hkC4Bbd8sVnc/GZzzr8+WK1WP+cyk8mkU3ctX778PIAJb7zxRovnn39+cFFRUb+Kiop2FRUVbYios9FohNbrrKqq
yq1toimQDdRviKK4QhCETjNmzLihoqKia0VFRes77rij9aVLl7y19auqqlqsWrXKW/aIQ0hIyC6z2Xy7Mi/OOS5fvnydUv/y5ct3nD59WqeaCg8PP7xkyZIM
AHjttdfaZmdn61IRRUVFZQiC0H769Ok6V+1WrVrpnld5eXnH+tbm4+PDe/To8d6GDRv2aNarvmSbzWZdmqOkpKQOZWVlO48fP37Gx8fnQmBgYEqbNm12Atij
rZeenj7x3LlzrbRlnTt3zi8oKLh3+nRHej0fH5+Q1q1b12RkZJgAu7q5qKioWSSXRpNL1qXsAZIS9WHnCDUDpbpLO+wN+k2XnJ20yGEYlvjp8G61OnHuahAb
vbIyJm72XSbvgK8lsFt0lmgGjdqLVMu8/t3fOX2M6n8sW1ScdUJwSzKOfVybrFIpBOwPxJb0afSSPVv5YrVdq4jAqZwoyh5HRJKOkNFIPmksOCfG2LiJ28Xh
n91p+VEpNpRjo82PL4RALR0vA5qfGgnIuUvGMABNJJesrKzxycnJPbRl11xzTVpJSUng9OnThyllAQEBqd26dStMTk5W/2hOnTrV84knnhgB4IemjHk1aNeu
3UEAKrmkpqa2TktLm/bEE0/8HBsbqxpUO3XqVBwWFvZeY/t9YNEDU3/Ej0+UotQ4AiN+G9Ry0GPNPPU6MWfOnKisrCyX1DJeXl5F2uupU6feefHixcdzcnL+
LzMzM7ioqIhpyd4ZNpvtim0uCkRRbJ2YmPhqZmbm4IyMjM75+fk+ZWV1p5arqakxVlVV+QCoBIBOnTptuPbaa2f9/vvvaiLSzMzMXq+88krIq6++mpWZmTmu
sLBQ1Wf5+Pjw0NBQ1ZssJyenT05Oji6g9MCBA10OHz7sEovmnJGhtra2XnKNioq6dNNNN9WZyqht27Y/BQQETCkqKjIqZRcuXGh54cKF/pB/B4ODg59NSUk5
0KlTp2fWrl37BwAUFxdHOM9l+/btg4hoEJzgHONUXV3dwrnOlaDR5CLZbD3IYBd57d619k/2fFxQNh273RmaF1wl6l31zJU7JICIuE2qfSc2Ovaqg++0sBOM
ON7kLcVLRMPk0dQMxPZadflwaYwnirKMFNdiQGu1cREeHBKJKiU59a2RQjggYav2jXvYz6IhBPScYvwnJauzVnKRB+VcMX241tGjfhGHg4gI8wGo5LL5XkvJ
lHhxOwd3Ix47SS3yXDV3XYylDSEzM/Me7R83ABw8eLDn0aNHf3KuW1mp875Gbm6uKTMzcwr+QnKJiIhY37FjxwcVjzBJkpCbm/u3qqqq4Ly8PJOm3u9vvvnm
mcb0OVWcevNv+M2ShayWgzDo/AA2YGVZWdm1ixcv1tUzS+buymdvePssXry4HwDMnz+/0Uk53SEtLe3x9PR0nfG5ZcuWUtu2bVW7w6RJk8RffvnlmfT09KuW
RhqLmTNndk1OTv587969vevyFGsIFoul5PDhw79pyeXs2bNt0tPTHwawNC8vT5dJoWfPnil9+vT5ULkuKyuLcP69q62tRX2kqqCmpsbsLlZIgdlszqvPnrZx
48ZNEyZMuOubb765U+vUoEV2drZ5586dwwYOHBj7zDPP3PbWW29drKmpcZFCq6rcTsEFVqu1WY4zb3ycCyGSGIO8k8n2CHnjUvYv2TdKtTaoIoIqI8gCjBw7
z7m1Wqr+vDkW4ozYaEtZTNxLE4xePt9xYjeooSoOfZdiwNeovMiRPsARE1Ov6os0H+y17f+3KwIBHcE4pZ+ptdbs0PYVUigN4wZDhE6UcpJ6tCwj64Ic8Thu
0YCsQwADGxwT9/K1sdF2PS8AcKu0DSZ2v4v/g3NKZVfppTuagFWrVnk7p3sBgPreTJ2Rk5MzQBRFg8ViaZ5EXg1g+fLliQkJCb+npaUNUcqysrJ61dTUhCjX
skH4l8b2mYWs6adg9+pJRWqn89L5rXXVLYY9Vm4f9o09LB0e2xM9swGE1FW/ITz99NPdTp8+PdZ58+7evfuFkJCQHQDw6KOPjnMmlpYtW1q7d+9+wcvLK9dk
MpUEBASYv/nmm5sbu4k1BCKiUaNGvf/zzz/31pShe/fu+YGBgZcEQSj09vYuycvL+7+jR492qq+v0NDQHX5+fhPKysoYYCeHnJyc65966qkbzp49G6Wt2759
+1+1maGNRmOZs8dZ69ata1u3bt1g9ujg4GBCPbZtQRDqfViccy6KYozRaFyRkpIy7uTJkxF1Pd9ff/21e3BwsAXAo4IguBBWeHh4pdlsbvBFPiAgoFmOMm80
uTCDEA4lTxh3ElFUI4S8E0vaMt19u2GDkz1OUpJ+T5gbe9ndeM2B2OjXi+/9ZO4d1MLne65RYzg2SnfEocxZ8YqSz3RRj3aRNYBKbTW9C9e9vmu3YJ3soI4t
5TMpJUk3ssDGaR+bqoDTauJcuELH7G5Qn+Si6vuYYPa6G4BKLqVVNT+3MAo2EBl0fTgTsstwFDzsHw977X7ow0btMElJSQ8nJSVdlY43OTk58tprr40B8MnV
9NMUyC6uQ2w2+9/qmTNn2jDGVGeGrl275oeGhv69sf3Z4Pibz0FOo9rkw+7cFYrQK05VP3PmzK6nT5/ecvz4cd3mzBhDRETEj8obd2Zm5iNaYgkKCqoYPXr0
wo4dO65SSP3BBx98uaam5uYrnYsznnjiiRFxcXE3astGjhy5p1+/fvcq9hAAGDhwYJJraz1CQ0M/6dGjx0uHDh1SX37y8/N7Xr58+YHMzEw1E2hwcHBV+/bt
P9K2DQgISPHz87OWl5er+2W3bt3SxowZc4dN+QWoBwsXLqy0WCwNVasTcpT+U8uWLZt/+vTp+/Py8vqUlpZGFBQURCYlJYVpp6CcgeTl5eUSrd+7d+9/9u/f
/9mGxjMajZUN1WkMGkUuw8RhBtb6mjacqXsdFOFD9+oOWSpReNolX4q9VLHKMLAj+JOxZcprhVN2iKNJol2csV4NGi30HKIYrB2OCU7VHJH4+m50XUDTl3oY
GEtwUQdKuJHrXpBIbcP1pY78ZdD8aAgu34XmgvNbAKg6mB1TXiucFL/oJAG9nCz6muaOA8c0PZpDzO39ATSKXNLT00dpvXAAoE2bNtDGDDijvLwcxcWOv53i
4mKWk5MzDn8huXTs2HFN9+7dH1XOarHZbND+kYeHhx9ZtmxZep0dOCEYwXuiEV3nGT0KvOHd5mt8fVchCjEKo373g99vvvBt6LdaB1EUWXFx8XWZmZkPnjp1
6g5nYgGAfv36nevZs6caW1NSUtJRe79z585pH374oS4zQUFBwfVXqLoio9Ho8ktcWFh48+XLl1Vbg+wg8U8tsTz22GO3X7hwIaKhASwWS83vv/9+CBrJ+vz5
8xGdOnUaqq0XGRl57N13392tLfPy8joeERFxPicnRzX6nz59umP37t1v+eijj9Zr686YMaNvQUHBgrZt285bs2ZNkjx2Q9OrF48++uhtNTU1wzdv3jyHc66e
JfXyyy8HBgQEfLd3717VGcZms/kBQNu2bX8OCAh4pqioSJWaLl682KtLly7Wt95666K2//vvv392bW1tp6ioqLkNnZPUFDROcml7rRcDN0haVyHHLmu3LcjK
L9Le125miq1AKSJAIjQ5avlK8MkYS96Ura/cBj/zLhBzOt1QM0k3H+WTMh2Cg5M9X7df6/Zqp8SPTlTDJQmT4sVJjIgkhSkYRTmN7nY9GrOVIylbnWhg33HY
TfqKosh+HgoWVIybGSGaEevoIo1p1WJ1SDBVzNoaaPj1WxTFoPT09P7aMqPRiDvvvHNZeHj4hrraJSYmLvr88891B4FlZ2f313oIuUNaWto1gwYNSqvrfufO
na2bNm3qWtd9LV599dWsI0eOJCQnJ7scKGY0GhESErKvMf0o+NDyYaOknNmLZw9lErsLACRIZ2ItsQ2erFlRUYEjR468P2TIEMlqtaK2ttYvMzMzKCsry+zO
yS4iIiK/R48eL1ksljylTHFJVpCRkRHy2GOPRb///vtxoij6nDx58vVff/11hEtnTvDy8ir38vLSqZMuX77c4tKlS0NFUdyZmZk5ff369cvlMXXqJM45ioqK
Bio2jGnTpo1KTEx8PSsrq1Fpotu3bx8bGBg4OT8/3wgA+fn5wk8//aSeG8QYc/u9WSwWa0JCwhEAKrkUFRUZf/vtt5cefPDBlpGRkRtrampKL126NDkxMfHF
Q4cOXRsZGTkwOjo6vmvXrnNee+21wsbMzx2effbZkNOnT6/8448/uo8dO7bnrFmzXl29evUvAGA2m11UX0ajsRgAgoKCvu/Zs2fi/v371ZirP/74o1NgYGDc
zJkzl3Tt2vXH6upqr8TExJf279//SEZGRpsBAwbcev78+Y2dOnVa6ZxC5krQKHJhldWBzNcLnEtccRhzGBm0NgXFxqxVmwHqhc7kwAHwrKtdQGPxyeRXc+7/
8pURNqP5JxDrrpE9HJUIak5N5chmRe+nLFxrNtFLJFDWZX86RHX7xhKBGLsNRCM4l4iI6axBWolFtdnoOuOA3WbVCJFFq9Jy6kMLRi2T+0jvBpewMRAoTF2f
+h1qCc9pWI2jBAdggsEbjUBKSsqsM2fOBGvLIiMjc8LDw1daLJY6D46aOXPm5qCgoGhtluGkpKQuJ06ceAh1ZCkGgIyMjBYZGRl1esJYrda0xsxbQVhY2C4v
L69Rzjrw7t27Z3fp0mV9Hc3+clRUVGDPnj2NsoV169YtZ8CAAa8558Xy9vbOAtBTub506VKr77777oOBAwfOr6ysbHXy5MmwugzOWsyZM6f466+/zgYc6YsK
CgoMO3fuXO/v71+ZnZ3durKy0vrxxx+v8vf3T/Tz8+NlZWXqL9x33313R0ZGRvJ3331XfeHChfDs7OxGnz+wbt26b2+66abEffv2qQb8/Px8dQ+85pprLoeH
h7vNRh4eHv5qz549hyQmJqpxYSdPnux44cKFNzp06DDHx8enKjU1NVhJsXLq1Kl2KSkpUydPntyDiAZfiat8XFyccPbs2U0HDhzowTnH119/Pap9+/Y3JyQk
nBMEoaK0tLTdiRMnVCcFQRAQHBycANgltdTU1M0nTpx4tbi4WJX+du/e/bc//vjjq/Dw8Nza2lrhzJkzQYpjwq+//hp15syZ1+++++5gAM83db7OaFQQJRO4
IOcHI0dgpPqTNJH5pETgQ84npovMJ8c/EMFArOJqF9AUbLrr1SxWy0cQl9x78CjJGWVoqcddqKKOmsjphnM6f1WDpRNvSLVJqW2drjUpZJRuyHkwN/OuE24n
DICDGAmPgyjMqdwhajbUu2OtjTIIZmdnD3b2uAkJCTlaH7EAwNq1a7/v1q2bTs9eWVmJrKyskY0Zt7nQvXv3DVFRURedy9u3b/+b9q3/PwE+Pj78lltuOTp0
6NApW7ZscXGNDQsL29aqVSvdl5WZmdni4MGDvY4fPx5WU1OD3r17FxgMDb+vtm/f/hfnemlpaQHHjx8PycnJMSckJDw3c+bMASEhIbEDBgzQ5QarqanBkSNH
Oh06dCgyOzvb19fX1xYZGdmo4GvOOQ8KCjpY1/2IiIjDdaky16xZk9S3b99FHTt21I1VUVGBU6dOBSYkJIQ65+4aNGhQYkBAwH1XGoP1yy+/XJeRkRGpbZ6Z
mel94MCBHvv27Rtw7NixDlpV7NChQ49fe+2185TrTZs2LR85cuRnLVq00Dm65OfnC8eOHQtJSkoK0v79eXl58SFDhuwYPnz4nCuZrzMaRS5VgH1TY8SJESdB
jsq30wnq/6dJC6MkslRTxLAreuhXg813WdIlqWYEgZ+Dk6sw17vUyj/rFw64PkLdFW4M4C7VeAOEAK2U5CxzOLuRuSrCdCRY3xOnxtRx4/LsUsYaNHI+//zz
kefOndO5gJpMJgQHB//cUFvOOQ8ODv7NuTwrK6u/KIqt3bX5M/Diiy+WhoSE6OZhNpvRvn17Fxfqf0f4+PigZ8+eObfccsve6Ojo54YMGXLDe++953buH330
0doRI0ZsCA4OdtHJC4KAwYMHJw8ePDheG6FfF3r06PH8qFGjfvbycn+iJueclZeX97dYLDVdunSZeeONN550129YWFjJHXfc8X6bNm3ONziojNDQ0A/Cw8PL
nct9fHwQGhr6XX1tP/744w233HLLw0OHDk3w8/OrU23Url276jvvvDO+d+/eo1avXt3ouTnjrbfe+u266667Z+TIkT8HBQXVacP09/e3jho16ufevXvfZbFY
dHa72NjYB8aOHfta3759Lzh7vClgjCEqKipnwoQJK2+//fZod8cRXAkapxaTeK1MJXoNiUNb5F5jor7x2m9yyC/ukt04Z+W2ZnF5ayq23rnkUky8ONIAaTcY
hXFidgLgsG/eGruLCnnhehuLhji4w0ajqsaUZloVmaZ/PfHwcwDCADLKjepxL9aibtuMdup1NycOSZNO3x3LNfYVQI7NsVlrGjTmV1VVhQ8YMCC2f//+au9G
o1GIiop6vzFDBQUFvRsTE6OLzBcEQSgqKuoAoMDX13dfdHR0k4jG19dX3TA6dOiwOzo6+pJybbC/artII8HBwe9GR0erObmMRiOLiopyCQoOCAjYFx0drXu6
3t7ep53rNQSTyVTQr7Lfziqqqm6N1qnO9w0GQ9n111//eZ8+ferc/IiowmQylXp7e6d07tx5x0svvdQom8Bnn3325NSpU/+ZkZFxf0lJSQcABrPZnBcUFJQQ
GRm5NDs7O3L8+PG12u/E19fXxWnHYrFUbNiw4bZWrVrNzsrKurGysjLYarWazWZzcWBg4KmwsLAVb7/9dgoAvPfeeweff/75IWFhYfNzc3N7V1VVtTSZTJX+
/v7n2rZtu+mDDz744eGHH349JCREjfMxm82spqbGre3t7bffPlpYWPj3qqoqnXrUZDJRhw4dGgzm/uCDD+Lj4uK+2blz5yO5ubk3lZaWhlmt1pacczKZTAUB
AQEXQkJCPl27du2Pzm29vLz2RUdH62yJvr6+9dom33vvvYMAhk2fPv2OvLy8O4qKirpWV1e3lCTJbDAYylu2bHkpODj42/Dw8C3u7CTyd7FAFMW3oqKinsnP
z+9RUVHRzmq1+hoMhkqTyVQcFBR0IiwsbP0bb7xxtqH1NwV1nnKrxbC1M/3MRqGYE7Sv9nKQoPLmrKpn1FgR/cu0+oatjMl5rTR916x1jY5gbm7ExM3vTkYh
QTAIPlAWoxriHXEudi0XdM5vjmBQuysy1wYUyn24bPuc26NTVAlBsoHzf9qs1r9fbm34NrgEh0CC/W3eaVCZnnWGK1L8C1Q3Cnc2GLtDghtxw75GIg7JniJH
4ygge8ApPuVa2nET+6OJjiXOeXVZSecvpjTfuRAeeODBfx4aJbm0bXu5srQwuJoz8rKHUcpQvIeUc1KULUg2igNqZd0+K4f3QzKiUZ45fxZSjiXdY/Aye3fq
eQ0MRqOL95NqOqnDEK6SiuNcFnW52sPC4EbdBi5VVldU9f1y4lLV/jM5ftEhAH01A7u2UwdvrEG/DsFDmay8QC5JsTU11n9AshmICQwC9zcZzf+AcvyxYyb1
jskBbq0SrjgBqQceePDfgUbZXOR4jBz1QDC7gZ6rdhQm26GVMu0/Jtd1Y+BnxJqcKqS50M8S/TAJTKypqqYLJ89ym80KMP359oqblsNdqw69kcag7tCRyZKA
GmTpBGLeJpNeCUoS/8EhDBIncNeARUWQsHvkOaw1jaIZpQ+Nyk3OB0egz76MXrzzy4lLd3wRvTieSSzNyXNAXW2d/XJO4Lz4uks+LjptDzzw4H8LjT/PhSHN
vcEenMBcCUU9PEyt5+ItRgJdP0x82L1V70/E9YtiJpAgrAeIMcZ4dUUlLiafg6QLttWm09fup/q9ldQ6TnflTMv6ynrtFDGDLi7AWlv8PSRe6OAMN8ThIAXF
Z9ndtHQNGhI1CCityC/X6YgNBsPNbuvXl+Hfvr4LzeEj74EHHvxnowmHhdEZJfuLTBSKCzLZJRcn7zH7SZVuvMYcRMQE1tIY5Hfbn7c8V/xtyZTbIRg3AzCS
wXEyZlVFBS6ePAtuk9B4C7Zi6nCk6tffc8g87kAMd2uvY6NXVgLcblTknLhq+3Bp6fq5zj2fXOUtzh2kBA4Ovnn7I47DyuTv9C4td2lX5aZ77WWTjdQeeODB
fx8aTS4M+EMT26InDXJs0qr6i5hDclGOOtacTMkYgcCImYXH/8wFanHj0vtuFYyGz8HgrZyAyQRGTJAJpqwC6SlpnEuKCsw96nKqcoaiVXK4AWtUXJwTJzZo
0lcvX6NvVPMmOC/R1qtLOUV6R4l6wV3qqC5xVTXW2mXaO3d//ko/TqQ7qU83H33HpC3joBP1z8QDDzz4X0CjycUm2X5VHJOgi29RpRZt/IpGWmEONZirSg2C
INw2+v2nbvjzlmjH0BWP3MJMhm1E5MMUYnEQDASBgRkYKkvLkZGaBi5J8t7N1XdzNfemc6yJG+lCS09cW0/bEcAYM+uOQf1k3Ks5JPGFpDse2Wkx9pPKHEfT
XOmhZQCXIC394q4lOs8uo9E4220wjnYNCrRHOXMOmyS5xJ944IEH/3toNLm0zMpNJKAIsjEfsnoMCsEwrUHf3rNCPEynMoNWtwYCBMFkXBsTJ/5pMS9Dlj10
B2cUD0a+qj1II0ExOasAYwxkYKgsK0fmuYt6kcCdXUW5btTmrqEa1W5B4AI9FBM3v5O2prU2aTW3ST9pDs3UgzT/nObWKMjkBC7tDsjO1Ektk756pSeIot2b
ariTSs0FNdWFVXVGQHvggQf/O2g0ucRaYmsg8b2q1CHvbnaiIQfJKIQCh3SiEJIbTzJuN0xTn7LyohV/xgKHvvnIg2Q2fAGCD0EhQg2ZCIyTLL0wgclkY5dg
ss+na6UNUgwrqpe19q3dGbqzWxRRRyMCKe7LnHkLJoPuKNvY6FgbVZRMAuen3PVPsjmnKWGWLnPjPLnaVh2zftp6Nf+DKIqMmGk1QAadLUUvpnFAk1mBa5Yp
8cNa281/M6aIUyKHiEP+MVIc+d3oRaMnNrbdJHHSG3/mvJobD7z6QP+xi8Y+/K8Ye8brMzqOWzSuwRTxADBx0cSlGzZsMDZcs2mIi4tzH9buQYNo/GFhAEAU
T8A41ZNJ+/asVOH2yAjVqUkTSqizVagxMvadkgnCk2M2zs7e8cjKpVe4Fh36b5hubFnFl5DR8DyHZHcIlmCPHSFN2I0EIuUIds5AXI7C5xwVpaXITktHcEQo
IEfxq05cHNpwSJfoD+KcuBxQSkR287xyYqQSxyIHaxJjd07+0nL/1rvETUr7TyavyJscL44gyfYNJ9ablN2eAMjn4XDtqLpIIu1ENFo4Ur4D/juhevSXE5bm
a6sm/580gzHZS0x3fLVmgWoMjtInKdIM5xzfNvS9AMDTy5/udqzi2Kct0dLKwW3lKC+vQtWZCGPEB5++/GlCY/r4V0IURdNlXH4/TAhb0FHoeCLHltPoTABl
vMzlmNl/Z1Rbqztn8aw+ACCKomEP7ZkbaYpcs/altVec6bexsNqswbk81+UgOXco5sWDsrKyBAANHw/ZAERR9NpLe1f6cb8etbxWevfku7WBhsCXvnj5i3/7
381/JzTBWwyw2vg2AlUTmGJz0f4fREQQHBIKI1LUZaoqyiHh6CUdAogZhcVjPnpu7ejVT13VudtD35oa5V+DPRDYCwCYzv2Z6XKbKddkt78QiDFiGueEitJy
yr2UxRXDujOJcCWAVAuyl5NrpgJAK4hwrkRfEjMZ3p3y9QLdOfJbx1kyy1ExBFyKU4Z21VXVr5Fzkns4uBRXwctv/mTcq7q0EzFx8/4mGAzLG+zSebWOxJqS
ZLV+Ve9klCZV3KeaqrO+tnx9/Q7Ljhtvxs33BrLAo+dqz60ftWhUdGP6+FfiDM4ML0Zx0ifzPvlp6dyllz+Y98H/hIdcqV9pQAEKRpTWlnZouLYDYxaNuWP8
ovFj/6x5NTd+xs+rjDBmbbdsH/rtwm+HtUXbZXm1eatJif72oFFoErnsfHRlATj/lhi4LpBSQyZM8xla7zKtWzJjLnEv9s0fxAT2uBBgOjJu4+wmuygPWzsz
+Na1M1YaTIYEMHYDAI0zARxzk1VfDESMkV01JjsfaI388k9eUVKGvMxsZzM+ADjYg2s2cjVMRas2I+h/QlWNcXtMZAuQYfvkeLG9tv/t45aVfnrnwklSbe0U
Ar9o75679lWHgswRyMkvcas05bM7F07cPk6vurr3y3kRgtn4BSfy0s2/gb616+CcH4mNXnxFm6zFYsndMX/Hxs6s82NlvOylf3dVRDGKgwUu1Ju5+b8RK55b
kXdswbEhm+ZvOt6UdqW8tFeZreyqThv9K+FDPn2/t3y/RLmOWxC3y0a28mdfe7ZTfe080KNpajEAIPZ3Ak2QNTPyUfTyPVnvRY6PSiPtbcXmoNkiue6FmICe
ZDJ8N/bj545IVv6hVFO584ac4IvOwXkkimx4q8wwGIXBRGysUWB3coKX4kpMEuOSIMmbJQGCrPNyzJCTIj3YlXPKac1wxHjYd9ry4lIQEQJDgqCERyoxLtrl
q3A5LEz/jNzd42CdCdI/Y+Lm3RYb7ThtTzHGg5wAACAASURBVE4+91lM3Ox4o9n/Uc4xnZj90DO70cr9aZggcEhSMuf87+UMG+MnWCo+5RZdlXu/nBdhMxh/
JGJhWv8Bl2zPXP+NOu7Z84pJktRg0r+G8On8T49fJ16X/8OZHwZEI1p1DHhWfDYgD3k3mJip+PbI2w83V9ZWIqJpC6f1rURlcJuWbQ6ufHal27Q1oij6ZJmy
eofUhJywWCxldtNdE50omgFPL3m6W4GtoIsf/BLWWda5Jbe4uDhhd/LuHtzMS9a9tC5NKRdF0ZBmSxsIA7w68o77lOOLnfHM0mfaFVoLr2vJW55fbVl9qrFz
U74jX4NvXog1JKGxgbSrV682Hys4NsBsNJcM6zYsqa7vVhRFlo/8yGIqjghsEXioru/KGY8veLx3hakiNEAI+O2due80eKS6KIoGDg7nNPle3Ms3mAU36Uj2
Z5Y906GgtqCnD3xS/j7v724PRnxx+YvBudW5/9deaP/70rlL3fY/+/XZnQusBV3bmdr9uuzF/xybZqMSV2oRExcj1NZ2/gOMrlXj8wiyzggEpp6ypYW8D8s7
O+eaQvmOepYlFHURhwR7yl5OXJJshRLnl4ijlHPOJc79CQjnhFbEiUtcsu+unINLdvsGBzjnkroxcodtAJzb7TDc/p88FlcyBKu/WxwAJNlwxEF+rf3Rul0b
uUtS7TAqZ0Euk+9xbYS/s81F83wISrJp4hxSmk2y3hl75yK3MSNERBO/fLkHM3gNlyTpOmLUFRydQdTO6bGnFZfk9f723nfcHp97zxcL+pqMhnjufIaLYlNy
rEvP/s7z4Twvv7i04/f3L29U2penFj/V+zA//OrBBQfHON/rK/aN62Pss+HDlz/850xxpt9JnHzXAENEEYqSDDC08Id/V5tg2/LDvB/eBYA7xDs+a8PavPXR
/I9+VfqYvmx6hwtVFzbstOy8Xdv3BHHCzj7oc5/FYskbs2jMyGpePa8MZZereXV+K9aqF+d87+6Fu+coX/4UccqePMp7X4AwrZSXngtD2OUKVPSpQlWLMioz
tuQtc40wGvqj/31JSNoWa4l1cakfJ457opqq236/4HsRAMYsHPPLjoU7GmV3EUXRkEzJP9rI9mylVPl6OcrLSlGaFUiBPa3cmjoUQx9Xzq8fJY7aGk7hn1/g
F54op/L81ry11A/9plgsFmm4Zfh0g2B4sBCFaVZutQYgIJKBvf9Pyz/VDL1PvvZk4Mnak+sECAFFKEr14l6hRhh9Qyhk1ynpVPCRhUeeBoDJiybv3bpg6xCl
3ezZs72P+x9fa4QxopAKE43cGOgHvw6CICwLrQk9ny6kryyjskBBEriZzPkt0ILHWeJGAcBIceQ0BvZQEYpOMzAvP/ILJ04Ld1p2/ggAU1+desMJ64mngxD0
IQefU4ziy2UoKw1EYE8bbEeHYuhTCondLt6+ZyAGjlRIc6w49uZKVIoVqCioRvXlAAT0tMF2ZBiGPdMQ8Q0Rh+xsi7ZLv7B8sRcA7lh8x1MVUsWNuy27JzXm
e5v6xtSwlMqUtQzMu4iKUlqgRVdIqO1i7vLQxrkbLwPAs289G3Ci+MQ6cLQppdKzLallVxu35Q3F0EcsFkuF8myT/ZM/qUENK+flF1tT6741qPl8l2XXW/ct
um9qBs+4drdlt4vDwz2L7hlbxavu2mHZ8S9xxFDQZMklNjrWNmHTCytJMLynyizKZqQx9DupVex7pk4lZCcPR/5+qJ1w2PV1nHHVeE0ktBYkHsjlfFuCrB2S
uKT4rTk2QyXVIoecoYuUl2+u2Km5xOQ6RArFKBNTE//Ka9KKBOVFJWCMwb9NK7jJaqlZs0wsSqZozcNwl/tRrUAAgXU0MOOBSV9ano86wd5z/mOQN79E+R8A
IGb7gl4CMx0HuEYkZBEBLQPfAvCItj0BNOkry2NGk2ElJ+arODHUOSf94BpRFTJn29Y0lljqgyiKrA216dSxtuOhuLg44TROx5lg2r7TsvNBpY68mW0eKY4U
vrd8/45Vsu4/T+dHAVDJJbUqNYaBRYmi2FI532KGOCOoHOXMYrHk3b347gHFvHh+R3R8aJNlU6o8tmEXdn08ctHImQDWAEAtaluauOneARgwQvumP2bRmEfB
EbHTsnOBWrZwjNs37hrUSBW84oolrRpe41PLa1eG+IU89P5z719Qym8Tb1u2i+9aZYFlFgAUo1gI5IEvtGAtZnw//3v1gK2RlpEPWpl1TBdzl1E75+wsBuxE
8nvN71/c/erdp7545Yu9GzZsMJ6qORXnQz4ffL3g6y1K23sW3HN9oVD4DwA/KGWlvFRVpRMRDV84PM7ETN9+N/87dSN7WHw4ON+W/4mPl8/kb1/+duRQcehL
Ahcqdy7cqR5Cdqd456Qqqrrrbz5/G7H8efvvzvRl0zukVqV++sILL/y6fLm9rCVatq9F7XOR/pF3r3pmVZEy7rCFw/6+G7sXWmBRvwMFUxZP6VGM4qUdTB0e
2zx3czJg/93ajd3v7cXeFwG8Xt8zb8PavJYlZS2/b9F9L2cjewY4qm7GzY/U10bB6tWrzalVqZ+0RMuV8Zb4bUr5HZY7pqfWpq4DcA8AnCg+sckkmOK/nfet
mhX+9sW3v7hb2r3YAstzAJDQKuEFL+518KcFPy2T12A4hmPLN2zYYLy+1fUff1PwzT5RFA3KC4aCXJ77QDCC6zyR9a9Ck2wuCoznLmyChPMgx/usYttwDpa0
Gzvs2hutAd9tUCWjeu5Djp1R7TMOt2KtTUe2p9gTYyoux06ZARzGfHLYYZhaR20jyG0ExkkTD1NWWIKS/CL5aWg0bRq401FBMf7XYxbkXDXh+DGjYe2p67Br
0pcLBjT0ncQdE5LApTSnzghgD06KX6C+ccXEvdJncrz4I4yG9QD5qU4F+skrX6qryzFzyo8mSfmsrMbt0bBNgSiKhl/wy3Ibtx22WCwlGxM3PlaFqrSdlp26
s+VXrlxZGYnIB22w3fvCCy/4dmVd48wwD9HWMcE0DBw7EihhglJ2ls5G17CanwEgS8p6qZ3UbrFCLID9nPQoY9RzNm67SylLR3obX8F3RV0qpL8COciJYGBv
a4kFAAZh0CsCCTc8/+bzbQCgGtU1OchJ+Hz+5yqxEBHZBNv0CEPE4+vnrC9WytfMXZMfQiFvZlozHwKAL7K+mFHDan7XEgsAfL7o80MlVPJpXXMbu2hsdCWr
vPzd/O/Wass/tHyY3Q/9hr/18lt1nlXS3rf9T129uj6iEAsArJ+z/mIZyo6m+6ffqpRlUVYPf/g/pxALYH+56u3fe44BhjtEUXTZw9KktDltqM0qhVgAwGKx
SH39+z4ncOGOuuakwMzM5UYyUipP/biNrc0HP1p+vE+RJgBgwqIJz4mi6OOu7TdF30y1cutvWmIBgG/Eb9YbubH17FdnhwJAV9Z1npZYAGCgNHCFL/ftr1yX
S+Udg1mw+n1aLBbrV5avnp02bVrtrFmzqkuoJCEBCTppasarM0K9uFdQrCX2X35g3RWRS6wltoYkPh8EHYmoHmAAlE3U1XDPHHXljV6fg0zTT50E5Nze7qjm
IBQCIwYSZL82JaZFIR2ZPJS6+nJHXaamtiFHmUByJH9ZhbWm5iMoai+nHdquJpSj/LV+wg5dIFQa0YFrPxFIGMqMhoOT4xd9O3Hb/PGjv3PvScctFkkC/8Kl
HCDGjGsnbrPcPWm7+JXgZT7Kid3imGg9tgPu5Oqsm7f9g2S1Ltoy5bUmu6XW8JqQgYsGzrlBvGFBX7Hv+t3Y/WsVqrwnhUx6GgCKWNHISEPkh+7avmt5t6wI
RQkpfil3vmt5N5tzzme8OiMUsOv+CSQEsaD4fOTfpI4n1QzvRt2+AoAWaNHxi0Vf/ODc7/qX12d5wUv9m2iBFiWfzfvM5dCnvxLe8C5w3qgA+0ZTRmVH08vT
BwGAFVapBbX4RVvn8YWP9yjhJWUfvfJRhnP7G3xu+Mmf/DsAQD7yh3Wp7eIyBgAE8SC3tgL8f3vnHl9Fde3x39pzTk4ICQmEtwKp1PoA9d722l6v9QlIFJJY
TCIoCEFraq0KigUROJkEFCxtKJYqD6WiFUgQAUG8gkDV9tZXpcUCRUCUN4GQF5zknJm97x8ze86cV3iFh5/u7+fDJyd7ZvbM2dG9Zq/fWmsD2M139+koOsYd
nxO5nl4Y88Khl3750j53m67rHdtSW63arHbctBq0zYv8i76Ivr58VHlNE5oONbRu6BF9LJVSr8junB3zfcpHldd4yGM0FzDSv6z/yAPGgekdRcdRbdCmrEqr
Gj32ubERG4s1isZBsDfojeYQP3Rdd637e/GO1aL2HwfEgWsB4MWJL0YERcyZM8dbZVZdoZHWSra1p/ZrtpvbnyiaXHRpvP56UI8/HsGRQe62LcaWYmIU9295
rjl1Qd/m6u2tFv3j8mAxNNwAW9wHEPaUJfIWwWV8pGhDsPPypIgTKR47GjjsFQGz7yFku5VV4szbznxuifhyGywmbNlDAOBSVBCWm8ySYyzR390P7IcV4cQP
YhBmyCwlvm06zCu90LQh0Y8to7QitAohk35cxiZeHLPljxN2GBkJYgCQzTy+7HSjQ/U9K0rXcW7+2TT435sC9TuTk9seqCjwB81gaDHz+Z6I7lQI0ZZ5PJWQ
u4Y6Sy0edarrCzhGU5B0EUZoRUJACPFF+uFDESuLkyWJkpoyKGMvCWIpLGVrVkrW09OfmO7s9JiBjI7djG4J8wpSKOWbGtRcBABBBN//yvwqH8Bvt2Hb4AAC
G4quKFr76pZXJwBW3kIKpWTMnTB3i67rKY1ozOhf0n91tp4d0y+BoOt6it/vP+6F97yLpz7yHUl0LAlJ+6thTcRJSPJkUEbE/u/1VH9pSIS6ZuvZ78S7noEd
BYAMZHTu1aZX3LH2wGPEawcAH3xZnUSn50/me8RjxOQRPXcaO0e1oTaXMzDWgIZAnahr1Y7a/dN1jwOJrj9Ox3fvPbb3GgBfudsNbmQs3b/0raX60phrDBja
9u3b2wGIEc8L9cL/CCBQdBWuun2Wf1YDgL/0K+1nfhz4+M3RM0bnl48qrxk3bly62co0EhlPH3ydasyaUdl69qPRx9KQpgV58AP5+4DSAUMCIvCTNKS1N2AY
tVptdRIlOZVKVk9avXBA6YDgLmPXnOtLrq/JpMyXVvhXrJTHF05c+EFfve8zxc8Ud5k9fvZ+XddZCqX07VXfq1/0vc8Hp21c/H4/z184phjM9zcQkuWkRFJw
STB/hkUa2IkgFDEhuzcjC18eE00W/kwAcfcRKe0IME6Cg7vC2oSVJOl+HpnpyAFB3Jl/ue2fIgCCCyLmFCkWgos/s5puv654zG8Wf1Y8on5PlwyhabeD3I9m
z8bRJfvdKwC5vXLMWDmjFFW4XxCI2gmifGIs36sJ4fVlgguBu5eXcM3rhRBh6SvSONp3FgAl3EI5TgXlWOMnLbEBM/SgO8P/FKlePXH1a4kOHsdxampqaos4
kwAAmDB9HngaAeA7nu+s2mnsfArAb4MI9uuJnmMLCgrMWfqsqgf0B3pXUdU1taL2I/vSoA++I9FifzwY2Bkn5J0pJCjhCiAogukZLGMvAHjh9fjgiwjc8DJv
ACb+/o7/nXubu4doZgM4A0bCOcKAEeKMt26u70QMKht03VF+9LlO1Km8X5d+jz/44IMhALhBv2GC+zwSlFCvEkJkJlFSzAuAj3xHV/tXn/DvG83X+HpwB9bh
1VkTZzXItjWT1szNLs02Pq/7fOkvnv1FwTbfthEhCiV0OXFwoyd6Pj7TP3NzonMAoI/e53kGlnJl0pUTfvfU75wNAweWDIxYfa6atOoNAG8UlhXetJ/vf/KW
0lt+vH7S+nHO/Yi//WXoyyIAz2xkG/Pref0mqVedb07LLSZZMmT6ViH4RCmmS0MhXWMR7qyI3wEQYsvBhP1oCGs0keeweJ9ZrKuNwKxtZmSZ/7iuN3dCJSy3
F6yk0IiKzlYeDNnfo444Rqy3RbTZP5gdOlJ3rBCm+SenZpeb8FbBLqKMjvsSp5yKICfM2DmGmPOF5fYjpnk0RsxD0ee6u4a9SkxUaTliY7NYM+OGG+bURYMm
n7U6YvWo/3KHb0fCqKqgCH6vs+i8BQBeefqVj9ugTZfnnnsuLRnJ6fP887YDgJe8H+zEzjuqRfVtPdBjJWC5kzzw8JbOpeHERbw+AwhknEm/BoyEk7cHnp6d
0ClhFepMM/PTdmh3caLjkjrUHdwS2HJ1vGNH2JGE15OgL/fwPVedqP947Bf7n7jYvHh8pb9yqTQsABAQgQ7u8wwYbRL10R7tL+qd0jvmv0EBYTz//POnnIht
kJGRKlJjXLzvTHpnfrJI/sOm4KalYBjUy9vrd4n6MGHuPMgO9m7uPuOfHd8BhGvW+Nfc7zYslZWVWpAF0+JdUzGx4k990TdXg3arruvOmFzR6or5GrTbAaBG
1NzTw9dj3sl813PBGRkXALh6S3I5OH/b0VgARFgYG7fgjyjtRJ5PMoMfJMV6ETYw4T6c65w+EPWTQIwEIxZjwJxrnB0yXboLyTaZUEmwjQrZgj7nhjnyvUdm
73CPwf8O+9UxM0g5TAj7rUOEtYxEmoZjNBJLHic6JgCSrjM57M0FC1i3jbg+QlcRkYaMYjSh8LXrhLm1pPk7nRk90GPZPuy7L96xe/R7Lm9Dbbpfhssc3aQa
1X/bGNg4w7VCwSXskhWM2I0ZlPGd1/2vfyjba1H791c3vzosut/KykqtsLTwydN53lrUHliyeUmMMTyGYwkN5Jw5c7yD9cG/TnQcAKpQ1TW/LP9H0e0jJo/o
mYrUdi9PfPmjeNcBwHT/9MMAjKFlQ2MMQPEzxV3ySvN+CgCZLHPNNr4tpj6aruusFW91V3S75BLvJW/Woa4wXub68CnDf6jrurXqIQhEmV2f8LXtntx9u7vt
Yf3hVAFxq7utlmqvKZ5R3CW6/4LSgj5NaDo4ZsyYmLf0Bmr46+rq1T+NbiciKiwtfDLe8wJAhsjYvlvsjhlrALiy9spKBkbHcZyFWoUSFtntxrpt2Mv3xg0a
yJuc99OHf/Vw51pRe1EAgZg8nVc2vzKkTtS1AayxHzl5ZMRY+P1+HhKho0dx1HlhmfXkrAMBBA6NLBs5VONa69fGvXbBVCU/Y+Pi9/s5IXAfcdpB1uaIzl/O
MhJSxA/Pfc4qRRoVguNRcusxEESyuGXCCLOIFUj0XjNRqxkp9Cfqx21k7P6YbWyYxgS4mLbukbmxjlwAFQX+hlBTYABx/jGASDHccYNFu6OaE6ZOIUnPKa6J
5u2R27ko3WOuPii8xzLCQlTUM3L+dVNtwxB76+uzxpv+N5clI7mqj95n7rhp49Jl+91ld1+/D/vmtmatJ7n93hfTxeu30baBWd4spwTN7Amzd3iEp/1RcTTC
RfHd5O9OqUHNzwaVDsqTbY+XP97uxc0vLqhGddw3xxPRSev0+93YXTbyNyO7AVb0W7aePb07undNdM3KAysH78XeZl3TWZR15DA/PL1gSsH/yLahZUOv2iV2
zUvWkp890XOlIe3Zr/nXvx/8zODvy7aiiUWXbg1tfa1JNNUCwP2X3/+Cj3xX3lF2xygZfTX2ubFpn9AnL6cjfXeivhc/vfj9JCRtvrnk5gU/n/rztrI9tyy3
cI+xp/xA6wPtAKAN2hwKiMAlAFBUVnRtZWWlxjS24a+hv46X9xs+ZfhFX+LLP3amzhG6UXfR/fC/av+1YNjkYZfJtrtK77rloDhY1oV1iQlDBoArPFdMO07H
78ktyy2UbY/qj7bpW9J33hEc6RKdICnphV5zANzYT+83yh2Fdnfp3f03pm9c7SHPq2mUNnNL7ZYlw6cNj1sCZ9mkZZWt0Cq9n96vRBbSrKys1LJLsx8LmIGC
m7Nurrr50ps3JYvkDoV64Y/ldXfod+QLiKLO6OxE2O3mu8cP1AcOlb8X6AW3ecnrneGf8Y37npnIrNzMN5cma8mV8Z7pfHHamoubioLfVBdWjh0ouO990tAB
iJD4bVhYbxCAzCW0kKpKlDjDbakEkU6aaIdN2CVnSxguvYEiVBxE34fCE74UuBG+oZDnQMDki68/1CnCHxw7DlNrf7JMz27lEasAdp2zMnBVVnYGQLrFnPtH
fUNLO+FxNkt2PZgloUBwEsQEOQ3u8yJHyrJbLrHefZxbdUZdq08R4dYTOCIagzlLh/3qjEqfGF6jPrUxdceJzltbsvZnt5Xc9sjG4MZluXouCRKsTtQd6uTr
NKpiXMVn7nN7i97Lj+HYXQueXvCpu72RNa7INDIj3uZeGfvKN/dOvnfYHnNPSY6eM0aDxo/jONegLX530rtOgIIX3rjPmMSSDqaaqREVeJdOWLoue0r2Rd/U
ffOHgfpADwiaIYy3TZhTUijFmXh9zOf0eUwcG5TFskqaG4Mm0VTdFm3HVBlVTw8oHZCpCc1sQENDOqWXLp+4fL08LxWpX3mTvTHJssv8y9bm6XnBg6GDpbl6
bhoANHgaAqlaavmqCatWAkBBQYG5dtragq2NWyd/Rp+9n6PnhAQThgFjAYF2p1O6Ex7rgy9iTN7zvzeqv97/0R3BHW/m6DkAgdWJup2Xp1+e/8Ioq4pATuec
1yr2VwzI0XPWNqGpbsOuDT+/ybzp2Q20Yeon4pP1uXquCCJ43AvvTANGVx+ztaNG1DIPW52sJf95n7lv5kB9YGsC8TrUHerKuj60aOIiJ+IqmZJ3QFj/A88d
P/fgvVPuHbLb2K3n6DmPaNB4I2vkAJa/N/G9GYnGeqZ/Zl3xjOK8TbWbSj6hTzYM1AcKjTQ6Io583Zl1Hi3DvAeUDgjWNtY+W15e/sDo0aMD7j6EEELX9cIN
tKF0xf4V763UVwoOTo3UuPEW3HKnrECweOriXxxuOlyWq+e25oKzIAW3ZiGr4CiOlgPWS/sD+gOFO7Fzel5p3kgSRPWoP5oZynwo+rm/j+8v+wAfTLiWX/uH
RN/tfHDKGfrNkb9o/I80n/ddEIX9pNZSRaa9SxMAyExF66OACO/BJYSd2cidqvJ2Wr2dRS8cVRl2uyPTC5koYs2kXEDYmfu2I0gAEdmU3K5eLDP0Ie0AnJla
mGJdk6d+4PoR808q36GwUk/1JNNSQdTXbVxssV1K7nBN8BH1CVwjJ8KrONsCyigyaUth+xCtG1C0OUG0hXHuQALg0rg6YxeOBoBjXAQgwNFAoWD2wvzJfzmZ
MVA0z0P6Qx13Ydcrq/2rb090jq7rno/x8bpV/lU3JjpHobiz9M6ial599fsl75/U9gTnijN2i7lZMviZj4TRNIAA681D6inOZAXbPRaOEbMmMynIhwtahv1o
Lo0mKscFLveV220GRlayH7N0/UT5MbHJlwRGzF0hGeD4kAUw6GQNC2C5yHxHRC5xvkiuTByd3rKI1mfXv9icEscOhgePIs8TkDsaCLkmRHQf4Z8UGW7gGC25
UHH21nFJK5ZdIoEaChkDlGFpOapQNVhj2gXlxlB8O6kX9UOyzKw5Jz7z3NKixgUAKgqmfmgaxu1EOAy4dH2XrgICYFdUhtRl5Au4k2TpEufj/UM4CdJJoowy
HIyYYHGuRfg8itZxwkaOACHWJlHDgLcfiV+bqznmj/A3XpaLoWSa05zlIcFeWpATZBw2va6xcbXEOMXiaTFy4zF3W/RZiXbLjHTZRdzTPrAXIaPPwvzSD+Jd
rjg9lviXzFw5ceXL5/s5FN9u7iy9M4eD1y4oW7DlfD9LNC1uXACgMn/yXwwjeAMJsR0xNSwp/q8U3eQ2MrI10jjIgwxh0T8cRCBXP/GMh9OXcG8bACn2W/Uy
X0cDz1k+8qXTTqTzw89fzyt5ipvmYBKiLnp2l4uGiAhjYbv2IqLN4oQsw153nMir6ToeYTTi1RNzlxS1CrB9Dh68buFdpZ9Hn6o4NzCwC3r7AcX5Ia8kb+G1
+rXz6kX9U1m+rNOKcDzbnBXjAgBL7npmKw8F/wecrwFcL+Rud4zUClztYQMge5KTPrNXNuT8lG43YS9C4ByX7rHwisZZIblWRFbYgbN8gX1JiBvG2FUjyoe9
/cjMppYYi0U/0SuF2fhDcG5P0hG5LJGLFtfPiHMSEW2rKfpY7LVhT1nY8IeFHlvS4vyPvAk3LcybnDBaSHF2KSkpMTuh0/Dz/RyKC4+u1PWxXtRr4Y248db5
4+bvOt/PE48WFfTjoUNnm5fyscyj+QEkgaz6yPYbuQxfElKNAGxB3xb8HfHfOiKL4TsKtxDWUS54WIuQ799OFBZcgr59jNuCfjhIAILz3WZTaNiq+2e8fzbG
4o7nH/Wld8t8CozGgpEvrLW4grTkSi88Gq6INtdnV0mzcPC3qyKygzO28gx7YWK3y60BIFdCosY0zMcqXFsuKxQKxaly1o2LZMgbk/4THu0FMPZD1z4ncYwL
AYI7k558TAAQVlisPRkKl9UgIayoJtihY7b27bS4Q9Fg/3AKmQnOOTfN+Zx5f7nyNIownir5b0zq5fVovxWM3QpEGxc7kI2sP46QliPCuAjH+MhN2+xLSdod
B6fsv9xfxjYskf0RIIQw+XIeanysomBqRBy9QqFQnCrnzLgA1kZjLKlXERF0EHURjlmRxkVOizz8OSpPxF5j2EaGh3UKO+4q4utwCAHOELksktcQIAQ3+Eem
EXz8rfvK/w/nmLuX+3MIbApjrJcIuyiFsxqJCD8GIlcu1h+PWw49eSW5R9EiduUSTrm0f+P8nyLEf7koX199tr+zQqH49+CcGhfJfa8+2TqYlvIAMTYKxHoA
gJ2nYiW4OMmGtsTsNi5w8iDttBXuxOw6wrjc1tLtFrM+Osse0zA/5aaYsmLotLdExEnnFh062/KmcScxzxPE2H8LJ1SMpLBv/drcysU2wMJeCTqGFLauEh2q
TGRZac6/4KY5FebWxWc7416hUPx7cV6Mi+S/5hR7e2Z2HMA8WpEgkk+nJAAAAh1JREFU1p8ISbakbM2P4WR6+a7tTKki3AZLh3ElUdrnOomWsCdczhu4wZca
odC8FcOmf4gLjMLKST/QPFoRGArAWAdbWyEBOwkVzvbJLtXJWuWE9ZvIqDAKf33pIjsOk6/g3Hj5yk2edSe717lCoVCcCufVuLgpnD++A2V472CE/iDWh4ja
CwKz8/jk+7hcr9gTrhTpASGi5kjL7WUKk1cLk6/h4G+Zx8Sq5SOnnfc9Ok5E8Zxib037zj8mRtlEdDMYXQNQEuDSieBaoVg6ilzZhTUYqz6YCS72AmI9N4x3
BTferiiYWhv3xgqFQtFCXDDGxY2u62xT76bveZj3B4xRby5wOQHdAdGFiFpxUBrZVccs15EICFPUg3BQcOwSgn8pOP8CJv+UeXZu/ba7fPJeHpuWnOG7mkC9
wdilBNENRB0h0AoED6wCagY4DBAOANjHBf+KA5spFPi8ouC5hBsuKRQKxdnggjQuzVFYWahVHWvt7XC0LeFiYM8e4KrWx4wz2LRKoVAoFC3Mt864KBQKheLC
56xl6CsUCoXi3xdlXBQKhULR4ijjolAoFIoWRxkXhUKhULQ4yrgoFAqFosVRxkWhUCgULY4yLgqFQqFocZRxUSgUCkWLo4yLQqFQKFocZVwUCoVC0eIo46JQ
KBSKFkcZF4VCoVC0OMq4KBQKhaLFUcZFoVAoFC2OMi4KhUKhaHGUcVEoFApFi/P/ztfhhPErzxwAAAAASUVORK5CYII=
'@
