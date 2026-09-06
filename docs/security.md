# Security and agent access

## Optional extended agent access

**Settings → Security** offers an explicit per-bot opt-in. All existing and new bots remain **Restricted** by default. Restricted agents continue to inherit SuperBot's App Sandbox. **Extended** agents run through the separately signed, hardened `SuperBotAgentHost.xpc`, outside that sandbox, as the current user (never root). This removes the inherited sandbox that prevented the browser-control runtime from applying its own sandbox. Browser/computer control still depends on the installed integration and macOS privacy permissions; a successful helper check does not prove browser access. Startup failures show their error and a **Retry Startup** button in Security. Starting a runtime checks for unread messages without consuming them, recovering pending notifications after a restart.

Enabling extended access displays a warning: tools may access files and signed-in browser sessions beyond the bot workspace. Connected MCP tools have their own permissions and may run outside Codex's shell sandbox; this is not a guarantee of approval before every action. Codex shell turns use `workspaceWrite` (the bot workspace and SuperBot's conversation store), restricted network access, and `on-request` approvals. The app renders command/file/permission requests and user questions in chat, with an orange sidebar indicator. Grants are single-command or current-turn only. Requests expire with their runtime/turn, and unsupported requests cannot be accepted with fabricated consent. Unattended heartbeats never approve requests.

Changing access stops the managed runtime process group before restarting. Restricted and extended modes use separate persisted Codex sessions; the conversation and bot workspace remain unchanged. Turning extended access off persists revocation first. Failed termination prevents an automatic replacement process. External applications already opened, detached services, and previously completed side effects are not undone by revocation. OS privacy grants must be revoked separately in System Settings.

The XPC service accepts only SuperBot's exact signed identity and signing team, and SuperBot verifies the helper's identity. It exposes no arbitrary executable/arguments/environment endpoint; it accepts a bot UUID and validates its existing workspace plus a vendor-signed OpenAI Codex executable bundled in `/Applications/ChatGPT.app` or `/Applications/Codex.app`. PATH-installed Codex remains supported in restricted mode only. Connections closing stop their managed process groups. **Test Extended Runtime**, under **Settings → Dev** in debug builds only, runs a fixed `sandbox-exec … /usr/bin/true` probe, without enabling a bot, invoking a model, or opening a browser. Smoke tests separately verify that a Foundation-launched helper starts in its own process group.

Plain MCP confirmation forms with no input fields (such as a browser destination prompt) show **Allow** and **Decline**. The app sends acceptance only after the user's click, with an empty response object; it does not fabricate field values or claim the tool's grant lasts only one command. URL/sign-in flows, forms requesting data, and unknown schema constraints remain unsupported and cannot be accepted.

## Security boundary

The finished app keeps App Sandbox enabled with these narrowly scoped entitlements:

- App Sandbox
- User-selected file read access, used only to import attachments
- Outgoing network client access, required by Codex
- A home-relative read/write exception restricted to `~/.codex/`, allowing the Codex child to use the user's existing login and persistent thread state
- The existing team-scoped sharing app group, shared only with SuperBot's share extension
- Exactly two update-installer IPC names: `com.pdparchitect.superbot-spks` and `com.pdparchitect.superbot-spki`

There is no broad home-folder, automation, camera, microphone, contacts, incoming-network, or personal-data entitlement. SuperBot explicitly points Codex at `~/.codex` but never copies or parses the credentials itself. The bundled Messenger helper is separately signed without the application entitlements.

The explicitly approved opt-in Agent Host is a second, distinct outside-App-Sandbox boundary. It has no extra entitlements, no root privileges, no login item, and no new global Mach-service exception. Absence of entitlements does **not** mean absence of access: the helper and its tools have ordinary user-process access, subject to macOS privacy controls and the harness/tool policies described above. `scripts/verify-agent-host.sh` verifies the assembled helper; the main app's reviewed six-entitlement policy remains unchanged.

Sparkle's framework runs inside the app sandbox. Its separately signed `Installer.xpc`, `Autoupdate`, and `Updater.app` form the explicitly approved outside-sandbox installation boundary needed to replace the app bundle. They have hardened runtime, the app's signing team, and no extra entitlement keys. `Downloader.xpc` is omitted because the app already has outgoing network access. `scripts/verify-updater.sh` checks the actual bundle's signatures, exact IPC names, signed-feed configuration, and absence of developer-machine framework search paths.

See [Architecture](architecture.md) for the process and data flow.


---

[Documentation](README.md) · [SuperBot](../README.md)

