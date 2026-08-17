# Pi Space

Pi Space is a local desktop interface for the [Pi coding agent](https://github.com/earendil-works/pi). It runs Pi in RPC mode and presents chats, tool activity, saved sessions, model selection, thinking levels, workspaces, persistent custom instructions, and click-to-start voice conversations in a desktop window.

Native macOS and Windows x64 apps share the same interface and core agent workflow. Both support local voice conversations while the in-app voice panel is active; Pi Space does not listen while idle.

> [!IMPORTANT]
> Pi Space is a client for Pi, not a separate AI service. You must install Pi and authenticate a supported model provider before using the app.

## What it includes

- Shared desktop interface with native macOS and Windows hosts
- Streaming assistant text, reasoning, and tool output
- Saved Pi session browser
- Workspace switching
- Model and thinking-level selectors
- Locally stored custom instructions
- Drag-and-drop and native file attachments
- Click-to-start in-app voice conversations on macOS and Windows
- Local Kokoro speech: MLX on Apple silicon and ONNX on Windows x64
- Voice transcription, streaming playback, interruption, mute, pause/resume, repeat, and immediate end cleanup
- Universal macOS builds for Apple silicon and Intel
- Native Windows x64 WebView2 app for chat, tools, sessions, workspaces, settings, updates, and voice

## Platform guides

- **macOS:** follow the quick start below.
- **Windows 10/11:** see the [Windows installation guide](docs/WINDOWS.md).
- **Linux:** not available yet; the shared host bridge is ready for a future native adapter.

## macOS requirements

- macOS 13 Ventura or newer
- [Node.js](https://nodejs.org/) 22.19 or newer
- Pi coding agent
- Xcode Command Line Tools when building from source

## macOS quick start

### 1. Download the app

Download `Pi-Space-macOS.dmg` from the latest [GitHub Release](https://github.com/bonnieBluesKid69/pi-space/releases/latest), open it, and drag **Pi Space** to the Applications shortcut. Public builds are currently unsigned and not notarized, so macOS may require Finder's **Open** command from the app's context menu. Never disable Gatekeeper globally.

To verify the download first, place `Pi-Space-macOS.dmg` and `Pi-Space-macOS.sha256` in the same folder and run:

```bash
shasum -a 256 -c Pi-Space-macOS.sha256
```

### 2. Install and configure Pi

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi
```

Inside Pi, run `/login`, choose a provider, and finish authentication. Exit Pi after confirming that you can send a message.

Pi Space is normally opened from Finder, so authenticating with `/login` is more reliable than relying on an API-key environment variable from one terminal window.

### 3. Build from source instead

```bash
git clone https://github.com/bonnieBluesKid69/pi-space.git
cd pi-space
./scripts/install.sh
```

This builds a universal app, installs it to `~/Applications/Pi Space.app`, and opens it. Voice is started only from the microphone control inside Pi Space; there is no background wake listener.

## macOS updating

Pi Space checks the latest versioned GitHub Release after launch. **Settings → Updates** can check manually and install a verified update when the app's containing folder is writable, including the default source installation in `~/Applications`. The updater downloads the exact macOS DMG and matching SHA-256 asset, validates the bundle and signature, preserves the existing app until replacement succeeds, and then restarts Pi Space.

Apps installed to system `/Applications` may require administrator permission to replace. In that case, download the latest DMG and drag the new version to Applications manually.

For source installations, the Git updater remains available:

```bash
./scripts/update.sh
```

The updater checks GitHub, fast-forwards to the latest `main` branch, rebuilds Pi Space, and reinstalls it.

Use `./scripts/update.sh --check` to check for a new version without installing it. The updater refuses to overwrite uncommitted changes, local commits, or divergent Git history.

## Using Pi Space

1. Open **Workspace**, choose the project folder you want to work in, and click **Apply**.
2. Return to **Chat** and enter a request.
3. Use **Sessions** to reopen an earlier Pi conversation.
4. Use **Settings** to change the model, thinking level, or custom instructions.

See [docs/USAGE.md](docs/USAGE.md) for the complete usage guide and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for common setup problems.

## Slash commands

Commands are handled locally by Pi Space unless marked **Pi RPC**. Slash commands are intercepted before they can be sent to the model.

| Command | Arguments | What it does |
| --- | --- | --- |
| `/model` | `model-id` | Switches the active managed model. |
| `/thinking` | `off`, `minimal`, `low`, `med`, `medium`, `high` | Changes the active model's reasoning level when supported. |
| `/key` | `provider api-key` | Updates an AgentRouter, TokenRouter, or TabiToken key without displaying it in chat. |
| `/compact` | none | Compacts older conversation context. **Pi RPC** |
| `/clear` | none | Starts a fresh session. |
| `/new` | none | Alias for `/clear`. |
| `/sessions` | none | Opens the saved-session browser. |
| `/workspace` | `[path]` | Changes the active workspace; without a path, opens a folder picker. |
| `/instructions` | `text` | Saves persistent local instructions applied to future prompts. |
| `/settings` | none | Opens Settings. |
| `/help` | none | Prints the complete slash-command list. |
| `/status` | none | Shows the active model, context usage, and session cost. |
| `/abort` | none | Stops the active response. **Pi RPC** |
| `/abort-retry` | none | Cancels an automatic retry delay. **Pi RPC** |
| `/abort-bash` | none | Stops the active shell command. **Pi RPC** |
| `/clone` | none | Duplicates the current session branch. **Pi RPC** |
| `/export` | `[path]` | Exports the current session as HTML. **Pi RPC** |
| `/auto-compact` | `on` or `off` | Enables or disables automatic context compaction. **Pi RPC** |
| `/auto-retry` | `on` or `off` | Enables or disables automatic retry. **Pi RPC** |
| `/voice` | none | Shows the click-to-start in-app voice controls. |

Type `/` in the composer to open autocomplete. Use the arrow keys to move through suggestions, Enter or Tab to select one, and Escape to dismiss the palette.

## Voice commands

The microphone button in Pi Space starts the voice conversation directly on macOS and Windows. Pi Space requests microphone and speech-recognition access, shows a live transcript, sends each turn after your selected Fast, Balanced, or Patient pause, and speaks the response. Recognition runs only while the in-app voice panel is active. **End conversation** stops recognition, generation, queued speech, and playback immediately in every voice state.

The glass voice stage includes microphone mute, pause/resume, repeat-last-answer, and response-timing controls. Settings also provides Concise, Normal, and Detailed spoken-response lengths. These preferences persist across launches.

In **Settings → Voice**, install Kokoro once, choose one of its local neural voices, and preview it. Kokoro is free and open, needs no API key or account, and runs locally after its initial download. macOS uses the MLX model on Apple silicon. Windows x64 installs a private embedded Python runtime and the checksum-pinned Kokoro ONNX int8 model under `%LOCALAPPDATA%\Pi Space\kokoro`; it does not modify system Python. The default voice is **Heart — warm**.

## Security

Pi runs local tools with your user account's permissions. Selecting a workspace changes Pi's starting directory; it does **not** restrict Pi to that folder or create a sandbox. Review tool activity and use a container or VM for untrusted work.

Read [SECURITY.md](SECURITY.md) before using Pi Space on sensitive or untrusted projects.

## macOS build from source

```bash
make check       # Type-check sources and scan for accidentally committed secrets
make build       # Build the universal Pi Space app into dist/
make test        # Build, validate the signature/bundle, and smoke-test Pi RPC
make install     # Install Pi Space to ~/Applications
make package     # Create the macOS DMG, ZIP archive, and checksums in release/
```

For architecture, signing, release, and development details, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## macOS uninstall

```bash
./scripts/uninstall.sh
```

This removes Pi Space but preserves Pi's configuration, credentials, instructions, and sessions in `~/.pi/agent`.

## Project status

Pi Space is an independent community client and is not affiliated with or endorsed by the Pi project. macOS and Windows x64 share the text-agent workflow and click-to-start local voice conversation. Windows voice requires an installed English Windows speech-recognition pack and microphone permission. Windows compilation, packaging, checksums, and lifecycle contracts are validated in CI; microphone routing, room acoustics, echo rejection, interruption thresholds, and display scaling still require broader testing on physical Windows hardware. Public builds remain unsigned, and Linux support is not available yet.

The current UI does not render RPC extension dialogs. Pi Space cancels those requests and shows an error rather than accepting them silently.
