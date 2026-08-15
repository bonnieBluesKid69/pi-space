# Development

## Architecture

Pi Space deliberately has no third-party application dependencies:

- `Sources/PiSpace.swift` creates the AppKit window, owns a `WKWebView`, starts `pi --mode rpc`, exchanges LF-delimited JSON objects, and manages session/workspace integration.
- `Resources/PiSpace.html` contains the shared interface, styling, and browser-side RPC event rendering.
- `Resources/pi-space-bridge.js` is the shared native transport adapter for macOS WebKit, Windows WebView2, and a Linux host hook.
- `Sources/WakePi.swift` is an optional macOS menu-bar app using AVFoundation and Speech.
- `scripts/` assembles ordinary `.app` bundles without an Xcode project.

Pi remains a separate global dependency. The app does not bundle Pi, Node.js, provider credentials, or user sessions.

## Platform bridge

The shared UI must not call a platform API directly. UI commands use:

```js
PiSpaceBridge.send("applyWorkspace", { path: "/path/to/project" });
```

The bridge adds `bridgeVersion: 1` and sends the flat message object to the active host transport:

- macOS: `window.webkit.messageHandlers.piSpace.postMessage(message)`;
- Windows: `window.chrome.webview.postMessage(message)`;
- Linux: `window.piSpaceHost.postMessage(message)`.

Native hosts send UI events through `PiSpaceBridge.receive(event, payload)`. WebView2 may instead post `{ event, payload }` to its browser message event. Event names continue to map to the existing UI handlers such as `rpcEvent`, `sessionsLoaded`, `providerSettingsLoaded`, and `voiceState`.

Every host should send `hostCapabilities` after navigation finishes. The payload includes `platform`, `bridgeVersion`, `voice`, `wakePhrases`, `kokoro`, `fileDialogs`, and `secureProviderConfig`. Unsupported features must be reported as `false` so the shared UI can disable their controls. Platform adapters own process spawning, secure configuration, native dialogs, audio, notifications, and packaging; Pi RPC behavior and UI state remain shared.

Run `node scripts/test-bridge.js` to validate macOS, WebView2, Linux-hook, inbound-event, and missing-host behavior.

## Prerequisites

- macOS 13+
- Xcode Command Line Tools
- Bash, `make`, and standard macOS developer utilities
- Node.js 22.19+ and Pi for the RPC smoke test

```bash
xcode-select --install
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

## Common commands

```bash
make help
make check
make build
make test
make install
make install-with-wake-listener
make package
make clean
```

`make test` performs source checks, creates clean universal bundles, verifies their property lists and signatures, checks both architectures, and sends `get_state` to a temporary Pi RPC process.

## Build options

The scripts accept environment overrides:

| Variable | Default | Purpose |
| --- | --- | --- |
| `ARCHS` | `arm64 x86_64` | Space-separated architectures |
| `MACOS_MIN_VERSION` | `13.0` | Deployment target |
| `BUILD_DIR` | `./build` | Intermediate binaries |
| `DIST_DIR` | `./dist` | App bundle output |
| `INSTALL_DIR` | `~/Applications` | Install destination |
| `CODESIGN_IDENTITY` | unset | Developer ID signing identity |

Example fast local build:

```bash
ARCHS="$(uname -m)" ./scripts/build.sh --pi-only --clean
```

## Signing and distribution

Without `CODESIGN_IDENTITY`, builds receive an ad-hoc signature. That is appropriate for local source builds but not ideal for public binary distribution.

For a Developer ID build:

```bash
export CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
make package
```

A maintainer distributing binary releases should then notarize each ZIP with their Apple Developer credentials and staple the notarization ticket to the app before creating the final archive. Never commit signing certificates, App Store Connect credentials, API keys, or notarization profiles.

## RPC notes

Pi Space treats stdout as strict JSONL and splits records only on LF (`0x0A`). Commands go to stdin as one JSON object followed by LF. Pi diagnostics are read separately from stderr.

When updating against a newer Pi release, test at least:

- `get_state`, `get_messages`, `get_available_models`, and `get_available_thinking_levels`;
- prompt streaming and `agent_settled`;
- tool start/update/end events;
- `new_session` and `switch_session` responses;
- model and thinking-level changes;
- extension UI requests.

The current UI explicitly cancels RPC extension dialogs. Do not silently ignore a dialog request: an extension may be waiting for its response.

## Release checklist

1. Update versions in `Resources/Info.plist`.
2. Read the upstream Pi changelog and RPC documentation for protocol changes.
3. Run `make test` on macOS.
4. Manually test chat, Stop, New Chat, session switching, workspace switching, model selection, and custom instructions.
5. Test the optional listener and permission prompts.
6. Run `make package` with the intended signing identity.
7. Notarize public binary builds.
8. Create a Git tag matching the version and attach the archives plus `SHA256SUMS.txt` to the GitHub release.

## Repository hygiene

The repository intentionally ignores `build/`, `dist/`, `release/`, `.DS_Store`, Xcode user data, and local environment files. The check script scans tracked source/documentation areas for common credential formats, but that scan is not a substitute for reviewing staged changes before every push.
