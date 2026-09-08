# Security and agent access

## Autonomous agent access

New bots start in **Restricted** mode. **Settings → Security** provides an explicit per-bot **Autonomous access** option. Existing bots retain their access settings: on upgrade, the previous default-on policy is saved once for the existing roster, while newly created bots receive no implicit grant. Restricted Codex bots run inside Noodle's App Sandbox. Claude Code currently requires autonomous access, so a new restricted Claude bot stays stopped with an explanation until the user enables it.

Bots with autonomous access run through the separately signed, hardened `NoodleAgentHost.xpc`, outside Noodle's App Sandbox, as the current user (never root). This removes the inherited sandbox that prevented the browser-control runtime from applying its own sandbox. Browser/computer control still depends on the installed integration and macOS privacy permissions; a successful helper check does not prove browser access. Unexpected runtime failures are retried automatically with bounded backoff, while Security keeps a manual **Retry Startup** control. Starting a runtime checks for unread messages without consuming them, recovering pending notifications after a restart.

Autonomous tools may access files and signed-in browser sessions beyond the bot workspace. Connected MCP tools have their own permissions and may run outside Codex's shell sandbox. Codex shell turns use `workspaceWrite` (the bot workspace and Noodle's conversation store), restricted network access, and runtime permission requests. Noodle accepts supported command, file, permission, and empty tool-confirmation requests immediately so the bot does not pause for approval. Permission grants keep the scope requested by Codex and are never made persistent by Noodle. Genuine questions that require information from the user still appear in chat. Unsupported requests fail closed rather than receiving fabricated consent.

Changing access stops the managed runtime process group before restarting. Restricted and autonomous modes use separate persisted Codex sessions; the conversation and bot workspace remain unchanged. Turning autonomous access off persists the restriction first. Failed termination prevents an automatic replacement process. External applications already opened, detached services, and previously completed side effects are not undone by restriction. OS privacy grants must be revoked separately in System Settings.

The XPC service accepts only Noodle's exact signed identity and signing team, and Noodle verifies the helper's identity. It exposes no arbitrary executable, argument, environment, or shell endpoint. It accepts a bot UUID, validates its existing workspace, and maps a provider identifier plus validated model/session choices to a reviewed fixed command. Codex binaries must carry OpenAI's signature; Claude Code must be Anthropic's signed native binary reached through `~/.local/bin/claude` and its versioned package. Arbitrary PATH shims are not accepted. Claude runs in stream-json mode with autonomous permissions only after the bot's Noodle access grant. Connections closing stop their managed process groups. **Test Autonomous Runtime**, under **Settings → Dev** in debug builds only, runs a fixed `sandbox-exec … /usr/bin/true` probe, without starting a bot, invoking a model, or opening a browser. Smoke tests separately verify that a Foundation-launched helper starts in its own process group.

Plain MCP confirmation forms with no input fields (such as a browser destination prompt) are accepted automatically with an empty response object. URL/sign-in flows, forms requesting data, and unknown schema constraints remain unsupported and cannot be accepted. They fail closed without pausing the bot for an approval card.

## Security boundary

The finished app keeps App Sandbox enabled with these narrowly scoped entitlements:

- App Sandbox
- User-selected file read access, used only to import attachments
- Outgoing network client access, required by Codex
- A home-relative read/write exception restricted to `~/.codex/`, allowing the Codex child to use the user's existing login and persistent thread state
- Home-relative read-only exceptions for `~/.local/bin/claude` and `~/.local/share/claude/versions/`, used only to detect and inspect Anthropic's native executable
- The existing team-scoped sharing app group, shared only with Noodle's share extension
- Exactly two update-installer IPC names: `com.pdparchitect.noodle-spks` and `com.pdparchitect.noodle-spki`

There is no broad home-folder, automation, camera, microphone, contacts, incoming-network, or personal-data entitlement. Noodle explicitly points Codex at `~/.codex` but never copies or parses the credentials itself. Noodle has no access to `~/.claude`; the isolated host runs fixed `claude auth` commands and returns only a signed-in boolean or a generic error. The bundled Messenger helper is separately signed without the application entitlements.

The autonomous Agent Host is a second, distinct outside-App-Sandbox boundary. It has no extra entitlements, no root privileges, no login item, and no new global Mach-service exception. Absence of entitlements does **not** mean absence of access: the helper and its tools have ordinary user-process access, subject to macOS privacy controls and the harness/tool policies described above. `scripts/verify-agent-host.sh` verifies the assembled helper; the main app has seven reviewed entitlement keys, including the two exact read-only Claude executable paths.

Sparkle's framework runs inside the app sandbox. Its separately signed `Installer.xpc`, `Autoupdate`, and `Updater.app` form the explicitly approved outside-sandbox installation boundary needed to replace the app bundle. They have hardened runtime, the app's signing team, and no extra entitlement keys. `Downloader.xpc` is omitted because the app already has outgoing network access. `scripts/verify-updater.sh` checks the actual bundle's signatures, exact IPC names, signed-feed configuration, and absence of developer-machine framework search paths.

See [Architecture](architecture.md) for the process and data flow.


---

[Documentation](README.md) · [Noodle](../README.md)
