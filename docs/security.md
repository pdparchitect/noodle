# Agent access and privacy

## Choose a bot's access

Every harness starts restricted: Codex, Claude Code, FX, Grok Build, Muse Code,
OpenCode v2, and Apple Intelligence. Unrestricted access is optional and set for
each bot.

Change a bot's access in **Settings → Sandbox**. Click the **Unrestricted**
heading or a bot's **restricted** or **unrestricted** label to see what that mode
allows. Turning on **Unrestricted** or **Apps** asks for confirmation first;
turning either off does not. Changing access restarts the bot and keeps its
conversation.

## Restricted access

A restricted bot works inside its own workspace. macOS enforces the limit on the
harness and on every command it runs, so it holds even when a model runs an
unexpected command or follows misleading instructions. A tool approval cannot
widen it. If Noodle cannot apply the restriction, the bot does not start.

A restricted bot can:

- read and write files in its workspace
- use the folders you share with it
- read and send messages in the conversations it belongs to
- use the tools, computers, and browsers you assign to it
- reach the internet, except Apple Intelligence, which runs on device

It cannot:

- read your personal files, other bots' files, or Noodle's settings and saved
  conversations
- change its own name, backstory, access, or shared folders
- use your Keychain
- start a server that accepts connections

### Shared folders

**Edit Bot → Harness → Folders** shares folders outside the workspace with one
bot, each as **Read & Write** or **Read Only** and with an optional description
of what it is for. Noodle refuses the whole disk and any folder that overlaps its
own storage. Saving restarts the bot.

Sharing a folder exposes everything in it to the bot's model provider and tools.
FX and OpenCode can also see the names of items in that folder's parent folders.

### Conversations

Bots reach conversations only through Noodle, which must be running. Noodle
checks who is asking and whether that bot belongs to the conversation on every
request, so a bot cannot pose as another bot. Attachments arrive as copies in the
bot's workspace, and a bot can attach only files from its own workspace.

### Sign-ins

Each restricted bot gets a private copy of your harness sign-in, with its own
settings, sessions, and caches. Noodle copies the sign-in only: the harness's
other conversations, global skills, hooks, and MCP configuration stay behind.

- The copies are the same account. Identity, quotas, billing, and revocation are
  shared, and the provider may ask you to sign in again when it rotates a login.
- A backup or copy of a bot's folder includes its sign-in. Treat it as a
  credential.
- A Codex, Grok Build, or Muse Code bot can use a
  [profile](harness-setup.md#profiles) in place of the system sign-in. A
  restricted bot cannot read other profiles.
- Where a harness keeps its sign-in in the Keychain, Noodle reads that one item
  for the bot. If macOS denies it, the bot fails to start with a Keychain-access
  error; its access is not widened.

## Unrestricted access

An unrestricted bot runs as your Mac user. It can reach files, signed-in
services, and browser sessions beyond its workspace, subject to macOS and tool
permissions.

Turning unrestricted access off does not undo completed actions, stop apps the
bot left running, or revoke macOS privacy permissions. Revoke those in System
Settings.

## Approvals

Noodle does not show per-action approval or question forms in chat. It accepts a
harness's tool approvals automatically, within the bot's access. Requests that
need an answer typed by you are declined; Noodle never invents an answer or
consent.

## What restricted access protects

- **Enforced by macOS.** File limits apply before the harness starts and to
  every process it launches, whatever the model is told or approves.
- **Your files stay private.** Personal files, the bot's own configuration, and
  Noodle's storage cannot be read or changed. Links, renames, and replaced
  folders do not get around this.
- **Bots stay apart.** A bot cannot read another bot's files or saved
  conversations. Noodle checks membership and assignments before releasing data
  or acting on a request.
- **Only genuine harnesses run.** Noodle checks the provider's signature on a
  harness before starting it, and a restricted bot cannot ask for wider access.

## Limitations

- **Allowed files remain writable.** A bot can damage or delete anything in its
  workspace and Read & Write folders. There is no review of edits and no
  rollback.
- **Shared data stays shared.** Members of a conversation can retrieve its
  messages and attachments. Copies already delivered to a workspace are not
  erased when a member is removed. Bots using the same sign-in share that
  account's permissions and billing.
- **Outbound networking is open.** Cloud harnesses are not limited to their
  provider's domains. Anything a bot can read can be sent to a remote service,
  including on your local network. Assigned tools, computers, and browsers have
  their own permissions; the file limits do not apply to what they do for a bot.
- **File names are less private than contents.** A bot may be able to see that a
  file exists, and its size and dates, without being able to read it.
- **Some tools fail when restricted.** Dependencies, caches, global skills, or
  services outside the allowed folders may be unavailable, and a harness update
  can add new requirements. A tool approval does not fix this; share the folder
  or make the bot unrestricted.
- **It is not a virtual machine.** There are no CPU, memory, disk, or spending
  limits. A signature check identifies a harness; it does not make its behavior
  harmless.
- **Command arguments are not private.** Other processes on your Mac may be able
  to read them. Keep credentials out of command arguments.

## Account apps

The **Apps** switch in **Settings → Sandbox** lets a Codex bot use apps connected
to its ChatGPT account, or a Claude Code bot use connectors from Claude.ai. Click
the **Apps** heading or a bot's **apps** status to see the explanation.

Apps are off by default. The preference is saved separately for each bot and
harness: enabling Codex apps does not enable Claude connectors when that bot
switches harnesses. Unsupported harnesses show a dash. Unrestricted access and
Noodle-assigned tools have separate settings.

Changing Apps restarts the bot and keeps its conversation. Noodle does not edit
either harness's global configuration, and provider or administrator
restrictions still apply when Apps is on.

This switch controls those account apps, not every remote tool or network
request. Apps use the permissions granted in the provider account. Turning Apps
off does not disconnect the account, undo completed actions, or erase data
already returned to the conversation. Manage individual apps and revoke their
account permissions in ChatGPT or Claude.ai.

## Connected tools

Assigning a [tool](mcp-connections.md) lets the bot use the permissions you
granted during sign-in. Noodle does not ask again for each call. Tool sign-ins
stay in the macOS Keychain and are never written to the bot's files.

A tool connection is a remote server. It can receive only workspace files the
bot chooses to send, and it cannot open workspace files or post into a
conversation on its own. Files a tool returns are saved in the workspace without
overwriting existing ones.

Removing an assignment blocks future calls; a call already sent may still finish.
Removing the connection deletes its sign-in from this Mac. To revoke the
provider's grant too, use that provider's connected-app settings. An unrestricted
bot's wider access means assignments are not a hard boundary for it.

## Noodlets

A noodlet a bot writes in [Noodle Applet](../Applet/README.md) does not widen
that bot's access. A noodlet can read only its own files and saved data. It
cannot read your files, another noodlet, or the Keychain; a file reaches it only
when you pick it in a dialog. Removing a bot from a conversation stops its
requests to shared noodlets, though one already running may still finish.

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

## How it is built

[Architecture](architecture.md#sandbox-and-launch-boundary) describes the launch
boundary, the sandbox policy for each harness, and how Noodle verifies the
harnesses it installs.

[Documentation](README.md)
