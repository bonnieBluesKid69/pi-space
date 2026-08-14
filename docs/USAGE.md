# Using Pi Space

## Before the first launch

Pi Space starts the `pi` executable in RPC mode. Set up Pi itself first:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
pi
```

Run `/login` in Pi and authenticate a supported subscription or API-key provider. Send one test message in the terminal before opening Pi Space.

## Chat

Open **Chat**, type a request, and press Return. Use Shift+Return for a new line.

While Pi is working, Pi Space displays:

- streamed reasoning when the selected model provides it;
- tool names, inputs, and live output;
- the final assistant response;
- a Stop button that aborts the active operation.

**New Chat** starts a new saved Pi session. Pi saves sessions under `~/.pi/agent/sessions/`.

## Workspace

The current workspace is the starting directory for the Pi process and its tools.

1. Open **Workspace**.
2. Click **Choose**, or enter an existing folder path.
3. Click **Apply**.

Applying a workspace starts a fresh Pi process and session in that folder. It does not erase earlier sessions.

> [!WARNING]
> A workspace is not a security boundary. Pi and its tools run with your macOS account's permissions and may access paths outside the selected folder.

## Sessions

Open **Sessions** to see saved Pi sessions from all workspaces. Each row shows the first user message and the last-modified date. Click a session to switch to it and load its active conversation branch.

Pi Space reads the same session files as the Pi terminal interface. You can move between the two interfaces, but do not actively write to one session from both at the same time.

## Settings

### Custom instructions

Custom instructions are prepended to every message sent from Pi Space. They are stored locally at:

```text
~/.pi/agent/pi-space-instructions.txt
```

These instructions are specific to Pi Space. They do not replace Pi's `AGENTS.md`, settings, skills, or system-prompt configuration.

### Model

The model list contains models that Pi reports as available with the credentials on this Mac. Selecting an item changes the active provider and model for the current session.

If the list is empty, authenticate in terminal Pi with `/login`, then restart Pi Space.

### Thinking

The available thinking levels depend on the selected model. Changing the model refreshes the supported levels.

## Optional voice listener

Install it with:

```bash
./scripts/install.sh --with-wake-listener
```

The **Wake Pi Listener** appears in the macOS menu bar. It recognizes English (Australia) speech and reacts to:

- **wake up Pi**: opens or focuses Pi Space;
- **time for bed Pi**: closes Pi Space.

The helper looks for Pi Space in `~/Applications`, the Desktop, and `/Applications`, in that order. It requires Microphone and Speech Recognition permission. Use its menu to pause listening, resume, open Pi Space manually, or quit.

To start it automatically after login, add **Wake Pi Listener** under **System Settings > General > Login Items**.

## Data locations

| Data | Location |
| --- | --- |
| Pi configuration and credentials | `~/.pi/agent/` |
| Pi sessions | `~/.pi/agent/sessions/` |
| Pi Space custom instructions | `~/.pi/agent/pi-space-instructions.txt` |
| Installed app | `~/Applications/Pi Space.app` |
| Optional listener | `~/Applications/Wake Pi Listener.app` |

Pi Space does not copy credentials or sessions into the repository or application bundle.
