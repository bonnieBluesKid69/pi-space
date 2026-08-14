# Pi Space

Pi Space is a small native macOS interface for the [Pi coding agent](https://github.com/earendil-works/pi). It runs Pi in RPC mode and presents chats, tool activity, saved sessions, model selection, thinking levels, workspaces, and persistent custom instructions in a desktop window.

> [!IMPORTANT]
> Pi Space is a client for Pi, not a separate AI service. You must install Pi and authenticate a supported model provider before using the app.

## What it includes

- Native Swift/AppKit application with a WebKit interface
- Streaming assistant text, reasoning, and tool output
- Saved Pi session browser
- Workspace switching
- Model and thinking-level selectors
- Locally stored custom instructions
- Optional menu-bar voice listener for "wake up Pi" and "time for bed Pi"
- Universal macOS builds for Apple silicon and Intel

## Requirements

- macOS 13 Ventura or newer
- [Node.js](https://nodejs.org/) 22.19 or newer
- Pi coding agent
- Xcode Command Line Tools when building from source

## Quick start

### 1. Install and configure Pi

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi
```

Inside Pi, run `/login`, choose a provider, and finish authentication. Exit Pi after confirming that you can send a message.

Pi Space is normally opened from Finder, so authenticating with `/login` is more reliable than relying on an API-key environment variable from one terminal window.

### 2. Build and install Pi Space

```bash
git clone https://github.com/bonnieBluesKid69/pi-space.git
cd pi-space
./scripts/install.sh
```

This builds a universal app, installs it to `~/Applications/Pi Space.app`, and opens it.

To include the optional voice listener:

```bash
./scripts/install.sh --with-wake-listener
```

The listener asks for Microphone and Speech Recognition access when first opened. It runs in the menu bar and can be paused or quit from its menu.

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
| `/voice` | none | Shows the Wake Pi voice command list. |

Type `/` in the composer to open autocomplete. Use the arrow keys to move through suggestions, Enter or Tab to select one, and Escape to dismiss the palette.

## Voice commands

Install the optional listener with `./scripts/install.sh --with-wake-listener`. After granting Microphone and Speech Recognition access, the listener runs in the macOS menu bar.

| Phrase | What it does |
| --- | --- |
| “Wake up Pi” | Opens Pi Space and starts voice dictation. |
| “Send it” | Sends the dictated prompt to the active local RPC session. |
| “Cancel” | Discards the current dictated prompt. |
| “Stop Pi” | Aborts the active Pi response. |
| “Repeat that” | Speaks the last assistant response aloud. |
| “Summarize this” | Requests a concise spoken summary from Pi. |
| “Time for bed Pi” | Aborts active work and closes Pi Space. |

Voice actions communicate through local macOS distributed notifications. No network listener is opened by Wake Pi.

## Security

Pi runs local tools with your user account's permissions. Selecting a workspace changes Pi's starting directory; it does **not** restrict Pi to that folder or create a sandbox. Review tool activity and use a container or VM for untrusted work.

Read [SECURITY.md](SECURITY.md) before using Pi Space on sensitive or untrusted projects.

## Build from source

```bash
make check       # Type-check sources and scan for accidentally committed secrets
make build       # Build both universal app bundles into dist/
make test        # Build, validate signatures/bundles, and smoke-test Pi RPC
make install     # Install Pi Space to ~/Applications
make package     # Create ZIP archives and checksums in release/
```

For architecture, signing, release, and development details, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Uninstall

```bash
./scripts/uninstall.sh
```

This removes the apps but preserves Pi's configuration, credentials, instructions, and sessions in `~/.pi/agent`.

## Project status

Pi Space is an independent community client and is not affiliated with or endorsed by the Pi project. The current UI covers the main chat workflow. RPC extension dialogs are not yet rendered; Pi Space cancels those requests and shows an error rather than accepting them silently.
