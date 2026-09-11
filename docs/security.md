# Agent access and privacy

## Choose a bot's access

| Harness | Access in Noodle |
| --- | --- |
| Codex | Restricted by default; autonomous access is optional |
| Claude Code, FX, Grok Build, Muse Code | Autonomous access is required |

Change Codex access in **Settings → Security**. The other harnesses' switches stay
on because they cannot run in restricted mode. Switching back to Codex restores
its saved preference.

Restricted mode limits the harness to its sandbox. Autonomous mode runs as your
Mac user outside Noodle's app sandbox. It can reach files, signed-in services, and
browser sessions beyond the bot's workspace, subject to macOS and tool permissions.
Noodle accepts supported tool approvals automatically; questions needing your
input still appear in chat.

Changing access restarts the bot. Turning autonomous access off does not undo
completed actions, stop detached applications, or revoke macOS privacy permissions.
Revoke those separately in System Settings.

## Connected tools

Assigning a tool lets the bot use the permissions you granted during provider
sign-in. Noodle does not ask again for each tool call. OAuth credentials stay in
the macOS Keychain and are not written to bot skills or request files.

Removing an assignment blocks future calls; a call already sent may still finish.
Removing the connection deletes its local credentials. To revoke the provider's
grant too, use that provider's connected-app settings. An autonomous bot's wider
system access means workspace assignment checks are not a hard isolation boundary.

## Files, recording, and computers

Noodle stores chats and bot workspaces locally. Your harness sends work to its
model provider under that provider's account and policies. Imported attachments
and backgrounds are copied into Noodle's storage.

Microphone access is requested when you start a [voice recording](voice-messages.md).
Transcription is on-device; sending shares the audio and transcript with the chat's bots.

[Noodle Computer](../Computer/README.md) runs Linux workspaces without mounting host
folders or sharing the host clipboard. Bots assigned to the same computer share
its files and services, with separate terminal sessions. Networking can reach your
LAN; Shell computers can have networking disabled.

## Implementation boundary

The Noodle app stays sandboxed. Autonomous harnesses run through the signed
`NoodleAgentHost.xpc`, which validates Noodle's identity, the vendor-signed harness,
and a fixed set of launch options. It runs as the current user, never root.
Sparkle's signed installer runs outside the sandbox to replace the app during updates.

See [architecture](architecture.md) for process boundaries and
[development](development.md) for bundle verification commands.

[Documentation](README.md)
