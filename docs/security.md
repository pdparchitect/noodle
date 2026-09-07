# Security and agent access

## Autonomous agent access

All existing and new bots use **Autonomous access** by default. They run through the separately signed, hardened `NoodleAgentHost.xpc`, outside Noodle's App Sandbox, as the current user (never root). This removes the inherited sandbox that prevented the browser-control runtime from applying its own sandbox. **Settings → Security** provides a per-bot opt-out for users who want a bot confined to its private workspace. Browser/computer control still depends on the installed integration and macOS privacy permissions; a successful helper check does not prove browser access. Startup failures show their error and a **Retry Startup** button in Security. Starting a runtime checks for unread messages without consuming them, recovering pending notifications after a restart.

Autonomous tools may access files and signed-in browser sessions beyond the bot workspace. Connected MCP tools have their own permissions and may run outside Codex's shell sandbox. Codex shell turns use `workspaceWrite` (the bot workspace and Noodle's conversation store), restricted network access, and runtime permission requests. Noodle accepts supported command, file, permission, and empty tool-confirmation requests immediately so the bot does not pause for approval. Permission grants keep the scope requested by Codex and are never made persistent by Noodle. Genuine questions that require information from the user still appear in chat. Unsupported requests fail closed rather than receiving fabricated consent.

Changing access stops the managed runtime process group before restarting. Restricted and autonomous modes use separate persisted Codex sessions; the conversation and bot workspace remain unchanged. Turning autonomous access off persists the restriction first. Failed termination prevents an automatic replacement process. External applications already opened, detached services, and previously completed side effects are not undone by restriction. OS privacy grants must be revoked separately in System Settings.

The XPC service accepts only Noodle's exact signed identity and signing team, and Noodle verifies the helper's identity. It exposes no arbitrary executable/arguments/environment endpoint; it accepts a bot UUID and validates its existing workspace plus a vendor-signed OpenAI Codex executable bundled in `/Applications/ChatGPT.app` or `/Applications/Codex.app`. The official standalone package is also supported through its current-package path, ~/.local/bin/codex, /usr/local/bin/codex, or /opt/homebrew/bin/codex. These fixed command locations may be installer symlinks; the host resolves them and verifies exact OpenAI signatures for Codex and all supporting tools. Arbitrary PATH shims are not accepted. Connections closing stop their managed process groups. **Test Autonomous Runtime**, under **Settings → Dev** in debug builds only, runs a fixed `sandbox-exec … /usr/bin/true` probe, without starting a bot, invoking a model, or opening a browser. Smoke tests separately verify that a Foundation-launched helper starts in its own process group.

Plain MCP confirmation forms with no input fields (such as a browser destination prompt) are accepted automatically with an empty response object. URL/sign-in flows, forms requesting data, and unknown schema constraints remain unsupported and cannot be accepted. They fail closed without pausing the bot for an approval card.

## Security boundary

The finished app keeps App Sandbox enabled with these narrowly scoped entitlements:

- App Sandbox
- User-selected file read access, used only to import attachments
- Outgoing network client access, required by Codex
- A home-relative read/write exception restricted to `~/.codex/`, allowing the Codex child to use the user's existing login and persistent thread state
- The existing team-scoped sharing app group, shared only with Noodle's share extension
- Exactly two update-installer IPC names: `com.pdparchitect.noodle-spks` and `com.pdparchitect.noodle-spki`

There is no broad home-folder, automation, camera, microphone, contacts, incoming-network, or personal-data entitlement. Noodle explicitly points Codex at `~/.codex` but never copies or parses the credentials itself. The bundled Messenger helper is separately signed without the application entitlements.

The autonomous Agent Host is a second, distinct outside-App-Sandbox boundary. It has no extra entitlements, no root privileges, no login item, and no new global Mach-service exception. Absence of entitlements does **not** mean absence of access: the helper and its tools have ordinary user-process access, subject to macOS privacy controls and the harness/tool policies described above. `scripts/verify-agent-host.sh` verifies the assembled helper; the main app's reviewed six-entitlement policy remains unchanged.

Sparkle's framework runs inside the app sandbox. Its separately signed `Installer.xpc`, `Autoupdate`, and `Updater.app` form the explicitly approved outside-sandbox installation boundary needed to replace the app bundle. They have hardened runtime, the app's signing team, and no extra entitlement keys. `Downloader.xpc` is omitted because the app already has outgoing network access. `scripts/verify-updater.sh` checks the actual bundle's signatures, exact IPC names, signed-feed configuration, and absence of developer-machine framework search paths.

See [Architecture](architecture.md) for the process and data flow.


---

[Documentation](README.md) · [Noodle](../README.md)
