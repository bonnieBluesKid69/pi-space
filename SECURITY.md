# Security Policy

## Supported versions

Pi Space is currently maintained on the latest source revision. Security fixes are applied to the current release rather than backported to older versions.

## Important security model

Pi Space starts the Pi coding agent as a local process. Pi's built-in tools and installed extensions run with the permissions of the macOS account that launched the app. They can read and modify files, execute commands, use available credentials, and access the network within those permissions.

The selected workspace is Pi's starting directory, not a sandbox or filesystem allowlist. Pi may access files outside it. Project trust controls whether Pi loads project-local settings and extensions; it does not constrain tool execution after startup.

Use a container, virtual machine, remote sandbox, or dedicated low-privilege account for untrusted repositories, prompts, dependencies, or unattended work. Mount only required files and provide only the credentials needed for the task. Review tool output and changes before accepting them.

Pi Space stores no credentials itself. Pi owns provider credentials and configuration under `~/.pi/agent/`. Pi Space adds only `~/.pi/agent/pi-space-instructions.txt` for its custom-instructions setting. Never commit either location.

The optional Wake Pi Listener continuously processes microphone input while active and authorized. Pause or quit it from the menu bar when it is not needed. Speech recognition behavior and data handling are governed by macOS and the user's system settings.

## Reporting a vulnerability

Do not include API keys, access tokens, private session data, or exploit details in a public issue. Report a vulnerability privately through GitHub's **Security > Report a vulnerability** feature when enabled for the repository. Otherwise, contact the repository owner through their GitHub profile and ask for a private reporting channel.

Include the affected revision, macOS version, reproduction steps, impact, and any suggested mitigation. Reports about Pi itself should be sent to the upstream Pi project according to its security policy.

## Scope

Expected behavior from running a local coding agent with the user's permissions is not, by itself, a Pi Space vulnerability. Relevant issues include unintended credential exposure by Pi Space, code execution caused by malformed RPC or UI content outside Pi's intended tool model, signature or packaging flaws, and permission handling defects in the optional listener.
