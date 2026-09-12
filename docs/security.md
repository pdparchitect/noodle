# Agent access and privacy

## Choose a bot's access

| Harness | Access in Noodle |
| --- | --- |
| Codex | Restricted by default; autonomous access is optional |
| Claude Code, FX, Grok Build, Muse Code | Autonomous access is required |

Change Codex access in **Settings → Security**. The other harnesses' switches stay
on after authorization because they cannot run in restricted mode. Selecting
one in the bot editor authorizes that harness for that bot. Copied bots may need
authorization in Security settings. Switching back to Codex restores its saved
preference. Editing `agent.json` alone never grants autonomous access.

Restricted Codex runs in a dedicated macOS filesystem sandbox applied to the
whole harness process tree. It can write its `workspace`, shared conversations,
the existing Codex account/session directory, and its workspace temporary files.
Its parent `agent.json`, layout metadata, Noodle-owned `runtime`, and Noodle
preferences are outside the writable boundary. System files, the app and harness
installation, and Noodle repository data are readable where needed; arbitrary
personal file contents are not granted. Outbound networking supports the model
connection and connected tools. This is not isolation between conversation
participants or between sessions using the same Codex account.

Autonomous mode runs as your
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

The Noodle app stays sandboxed. Harnesses run through the signed
`NoodleAgentHost.xpc`, which validates Noodle's identity, the vendor-signed harness,
and a fixed set of launch options. Restricted Codex and Apple receive their filesystem
policy before the harness executable starts; failure to apply it prevents
startup. The host accepts no caller-supplied sandbox profile, arbitrary command,
or writable roots. Autonomous harnesses use the separate authorized launch path.
The host runs as the current user, never root. App and helper entitlements are
unchanged by the workspace migration.

The built-in `NoodleAppleAgent` is verified against this app's exact helper path,
signing team, and helper identifier. It has no extra entitlements and does not
inherit the app sandbox. Agent Host applies its own deny-by-default policy before
execution: system and Noodle repository reads, workspace and conversation writes,
read-only model-availability and global preferences, and the Apple model-manager
service. Outbound network and unrelated user files are denied. Its initial
Default model runs on device through Foundation Models. The existing per-bot
autonomous setting enables broader user-level access through the same authorized
launch path as other harnesses. The app's entitlements remain unchanged.
Sparkle's signed installer runs outside the sandbox to replace the app during updates.

See [architecture](architecture.md) for process boundaries and
[development](development.md) for bundle verification commands.

[Documentation](README.md)
