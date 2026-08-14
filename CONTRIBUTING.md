# Contributing

Contributions are welcome for focused bug fixes, compatibility updates, documentation improvements, and complete UI features.

## Before opening a pull request

1. Open an issue for behavior changes or substantial features so the approach can be agreed first.
2. Keep changes scoped and preserve the dependency-light native structure unless a dependency solves a clear problem.
3. Never include Pi credentials, session files, custom instructions, personal paths, signing material, or generated app bundles.
4. Run `make test` on macOS.
5. Manually exercise the workflows affected by the change.

## Code style

- Follow the formatting already used in the Swift and HTML files.
- Keep comments limited to behavior that is not evident from the code.
- Treat Pi's RPC documentation as the protocol source of truth.
- Handle RPC failures and extension UI requests explicitly; do not leave the agent blocked waiting for input.
- Preserve the macOS 13 deployment target unless a change is discussed first.

## Testing checklist

Depending on the change, verify chat streaming, tool output, aborting, session creation and switching, workspace changes, model selection, thinking levels, saved instructions, app relaunch, and the voice listener's permission flow.

## Pull requests

Describe the user-visible behavior, why the change is needed, test commands run, and any Pi versions used during testing. Include screenshots for interface changes and call out known limitations or follow-up work.
