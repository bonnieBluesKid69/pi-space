# Windows Installation

Pi Space for Windows is currently a source-available preview built with .NET 8 and Microsoft Edge WebView2. It reuses the same Pi Space interface and bridge as macOS, while Windows-native behavior lives in `Platforms/Windows`.

The preview is intended for personal testing of the text-agent workflow. It is not a signed or notarized release yet.

## What works

- Streaming Pi chat, reasoning, and tool activity
- Stop, compact, and new-session controls
- Saved sessions and session switching
- Workspace selection and reconnect
- Native file attachments and drag-and-drop
- Model and thinking-level controls
- Persistent local instructions
- Provider configuration with local file-permission protection
- Clipboard support

## Current limitations

- No Windows voice conversation yet
- No wake phrases or Kokoro TTS yet
- No signed MSI, MSIX, or installer package
- RPC extension dialogs are cancelled because the shared UI does not render them yet
- Windows hardware, audio, and installer behavior still need broader testing

Do not treat the preview as a finished Windows release or as an executable from an established publisher.

## Prerequisites

Install these before starting Pi Space:

1. **Windows 10 version 1809 or newer, or Windows 11.**
2. **Microsoft Edge WebView2 Runtime.** The Evergreen Runtime is available from [Microsoft's WebView2 page](https://developer.microsoft.com/microsoft-edge/webview2/). Many current Windows installations already include it, but the app will show an error if it is missing.
3. **Node.js 22.19 or newer.** Install it from [nodejs.org](https://nodejs.org/).
4. **Pi coding agent.** Open PowerShell and run:

   ```powershell
   npm install -g --ignore-scripts @earendil-works/pi-coding-agent
   pi --version
   ```

5. **.NET 8 SDK** if building from source. Install it from [dotnet.microsoft.com](https://dotnet.microsoft.com/download/dotnet/8.0).

## Option A: Download the CI preview

The repository's Windows workflow publishes a `Pi-Space-Windows-x64` artifact for successful builds.

1. Open the repository's [Actions page](https://github.com/bonnieBluesKid69/pi-space/actions/workflows/checks.yml).
2. Open a successful run for the commit you want.
3. Download **Pi-Space-Windows-x64** from the **Artifacts** section.
4. Extract the ZIP to a folder you control, such as `%LOCALAPPDATA%\Pi Space`.
5. Run `PiSpace.exe`.

The artifact is framework-dependent and requires the **.NET 8 Desktop Runtime** as well as WebView2. Install it from the [.NET 8 download page](https://dotnet.microsoft.com/download/dotnet/8.0) if it is not already present. The CI artifact is not code-signed. Verify that the download came from the official repository workflow, inspect the commit and workflow run, and review the source before using it with provider credentials or untrusted projects.

Windows SmartScreen may warn because the executable is not signed. Do not bypass security prompts for an executable from an unverified source. For a trusted repository artifact, use **More info → Run anyway** only after verifying the workflow, commit, and extracted files yourself.

## Option B: Build from source

Clone the repository and build the Windows shell from PowerShell:

```powershell
git clone https://github.com/bonnieBluesKid69/pi-space.git
cd pi-space
dotnet build Platforms/Windows/PiSpace.Windows.csproj --configuration Release
dotnet run --project Platforms/Windows/PiSpace.Windows.csproj
```

To create a publish directory:

```powershell
dotnet publish Platforms/Windows/PiSpace.Windows.csproj `
  --configuration Release `
  --runtime win-x64 `
  --self-contained false `
  --output .\dist\windows
```

Start the published build with:

```powershell
.\dist\windows\PiSpace.exe
```

Keep the published `Resources` directory beside `PiSpace.exe`. It contains the shared HTML, bridge, and bundled browser resources used by the application.

## First launch

1. Start Pi Space.
2. Open **Settings** and configure a supported provider, or authenticate with Pi first:

   ```powershell
   pi
   ```

   Then run `/login`, complete provider authentication, send a test prompt, and exit Pi.
3. Open **Workspace**, choose a project folder, and click **Apply**.
4. Return to **Chat** and send a test request such as `List the files in this workspace`.
5. Use **Sessions** to verify that the conversation appears in the local session list.

Pi Space starts Pi as a local child process with the selected workspace as its working directory. The workspace is not a sandbox or filesystem allowlist.

## Files and configuration

The Windows preview uses Pi's normal configuration and session locations under your Windows user profile. Pi owns provider authentication and model configuration. Pi Space stores its persistent instructions in:

```text
%USERPROFILE%\.pi\agent\pi-space-instructions.txt
```

Provider keys written through the Windows Settings view are stored in Pi's `models.json` configuration with an atomic replacement and current-user-only ACLs. Never paste provider keys into chat, issues, screenshots, or logs.

## Updating

The Windows app checks the latest **versioned GitHub Release** after startup. It does not install from `main`, pull arbitrary source changes, or trust CI preview artifacts. If a release contains both `Pi-Space-Windows-x64.zip` and its matching `.sha256` file, Pi Space shows an in-app notice with **Update now**. You can also open **Settings → Updates → Check for updates**.

Before replacing files, the updater downloads the release ZIP, verifies its SHA-256 checksum, checks the package contents, launches a temporary PowerShell installer, and restarts Pi Space. If replacement fails, the existing executable is started again and the error is written to `%LOCALAPPDATA%\Pi Space\update.log`.

Releases are created by tagging a commit whose Windows project version matches the tag, for example:

```powershell
git tag v0.3.0
git push origin v0.3.0
```

The `Windows Release` workflow publishes the ZIP and checksum to the GitHub Release. Release signing is still separate work; unsigned Windows releases may trigger SmartScreen warnings.

## Troubleshooting

### WebView2 is missing

Install the Evergreen WebView2 Runtime from [Microsoft](https://developer.microsoft.com/microsoft-edge/webview2/), then restart Pi Space. The runtime is installed separately from the .NET SDK.

### “Pi was not found”

Confirm that PowerShell can find Pi:

```powershell
Get-Command pi
pi --version
```

If it is missing, install it again with npm. If Pi was installed through a Node version manager, restart the app after ensuring its executable directory is on `PATH`.

### No model or provider authentication

Run Pi directly and complete `/login`. Then send a test prompt in terminal Pi before reopening the desktop app. Temporary `$env:API_KEY` values in a PowerShell window are not a reliable configuration method for a desktop launch.

### The app starts but does not show the interface

Confirm that `Resources\PiSpace.html` and `Resources\pi-space-bridge.js` are beside the executable in a published build. For a source run, rebuild from the repository root so the project content files are copied to the output directory.

### The workspace does not open

Choose a folder that exists and that your Windows account can read. Pi may still access paths outside the selected workspace because the workspace is only Pi's starting directory.

### A provider key was exposed

Revoke or rotate it in the provider dashboard immediately. Do not commit the key or include it in a GitHub issue. See the repository [security policy](../SECURITY.md) for private vulnerability reporting.

## Security

Pi runs local tools with your Windows account's permissions. Review tool activity and changes before accepting them. Use a Windows sandbox, virtual machine, separate low-privilege account, or other isolation for untrusted repositories and prompts.

Read [SECURITY.md](../SECURITY.md) before using Pi Space with sensitive projects.

## Feedback

When reporting a Windows issue, include:

- Windows version and architecture
- Pi Space commit or CI workflow URL
- .NET SDK/runtime version
- WebView2 Runtime version
- Pi version
- Reproduction steps and sanitized error output

Never include API keys, access tokens, private session contents, or unredacted workspace paths in public reports.
