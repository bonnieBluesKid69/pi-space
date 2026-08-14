# Troubleshooting

## "Pi was not found"

Confirm that Pi is installed and available:

```bash
command -v pi
pi --version
```

If it is missing, install it:

```bash
npm install -g --ignore-scripts @earendil-works/pi-coding-agent
```

Pi Space checks common Homebrew, npm, Volta, asdf, mise, nvm, and fnm locations and finally asks your zsh login shell. Restart Pi Space after changing your Node or Pi installation.

## No model appears, or a provider says authentication is missing

Authenticate through terminal Pi:

```bash
pi
```

Then run `/login`, select a provider, complete authentication, and test a prompt. Quit and reopen Pi Space.

Finder-launched apps do not inherit temporary `export API_KEY=...` values from an existing terminal. Pi's `/login` flow stores credentials in `~/.pi/agent/auth.json` and is the recommended setup for Pi Space.

## The app is blocked by macOS

Source builds are ad-hoc signed unless the builder supplied a Developer ID identity. A downloaded, non-notarized build may trigger Gatekeeper.

Prefer building from source or downloading a notarized release from a maintainer you trust. Do not disable Gatekeeper globally. If you trust the exact download, use Finder's **Open** command from the app's context menu and review macOS's warning.

## A workspace's local Pi extensions or settings are ignored

Pi Space uses Pi's non-interactive RPC mode. Pi's project-trust rules apply, but RPC mode cannot show the normal terminal trust prompt.

Open terminal Pi in that project and save a trust decision:

```bash
cd /path/to/project
pi
```

Use `/trust`, then restart Pi Space in that workspace. Only trust projects whose local extensions and settings you have reviewed.

## The voice listener cannot find Pi Space

The helper searches these locations:

1. `~/Applications/Pi Space.app`
2. `~/Desktop/Pi Space.app`
3. `/Applications/Pi Space.app`

Run `./scripts/install.sh --with-wake-listener` to place both apps in the recommended location.

## Voice commands do not work

Check **System Settings > Privacy & Security** and enable both:

- Microphone access for Wake Pi Listener
- Speech Recognition access for Wake Pi Listener

Use the menu-bar icon to confirm that listening is not paused. The recognizer currently uses the `en-AU` locale.

## A session will not open

Pi Space lists `.jsonl` files under `~/.pi/agent/sessions/`. If a file was moved, corrupted, or created by an incompatible Pi version, it may not switch successfully.

Update Pi and test the session with terminal Pi:

```bash
pi update --self
pi -r
```

Pi Space does not delete session files when a switch fails.

## An extension dialog was cancelled

The current Pi Space UI does not implement RPC extension dialogs such as select, confirm, input, and editor prompts. It responds with cancellation and displays an error so the extension does not remain blocked. Run that workflow in Pi's terminal interface, or contribute dialog support.

## Build fails

Install Apple's command-line tools:

```bash
xcode-select --install
```

Then check the toolchain and run the full test:

```bash
xcrun swiftc --version
make test
```

The default build targets macOS 13 and produces both `arm64` and `x86_64` binaries. To build only the current architecture during development:

```bash
ARCHS="$(uname -m)" make build
```
