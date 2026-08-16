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

## Kokoro installation ends with an error

Kokoro requires an Apple silicon Mac, Python 3.10, 3.11, or 3.12, free disk space, and internet access for the initial dependencies and model download. Python 3.9 is not supported. Pi Space shows the final installer step in **Settings → Voice**, keeps the failure visible there, and provides **Open install log**. The complete output is also written to:

```text
~/Library/Logs/Pi Space/kokoro-install.log
```

The installer searches Homebrew and python.org locations even when Pi Space was launched from Finder. A retry builds a separate environment and does not replace a working Kokoro installation until dependency imports succeed. To install a compatible interpreter manually, use Python 3.12 from python.org or:

```bash
brew install python@3.12
```

Then click **Retry Kokoro installation** and review the end of the log for package download, disk-space, certificate, or network errors.

## An in-app macOS update cannot be installed

The in-app updater can replace Pi Space only when its containing folder is writable. A copy in system `/Applications` may require administrator permission, and an app launched directly from a mounted DMG is read-only. Pi Space now detects either condition before downloading the update, labels it **Manual installation required**, and provides **Download DMG** instead of reporting an update-check failure. Quit Pi Space after downloading, open the DMG, and drag Pi Space to Applications to replace the old copy. Install the app under `~/Applications` to enable verified in-app replacement for future updates.

Pi Space rejects an update if the DMG checksum, bundle identifier, required executable, or bundle signature validation fails. Details from replacement failures are written to `~/Library/Logs/Pi Space/update.log`.

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
