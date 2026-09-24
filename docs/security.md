# Agent access and privacy

## Choose a bot's access

Every bot starts with restricted access. Unrestricted access is optional and set
for each bot.

Change a bot's access in **Settings → Sandbox**. Click the **Unrestricted**
heading or a bot's **restricted** or **unrestricted** label to see what that mode
allows. Turning on **Unrestricted** or **Apps** asks for confirmation first;
turning either off does not. Changing access restarts the bot and keeps its
conversation.

## Restricted access

A restricted bot works inside its own workspace. The limit holds even when a
model runs an unexpected command or follows misleading instructions, and
approving a tool cannot widen it. If Noodle cannot apply the limit, the bot does
not start.

A restricted bot can:

- read and write files in its workspace
- use the folders you share with it
- read and send messages in the conversations it belongs to
- use the tools, computers, and browsers you assign to it
- reach the internet, except Apple Intelligence, which runs on your Mac

It cannot:

- read your personal files, other bots' files, or Noodle's settings and saved
  conversations
- change its own name, backstory, access, or shared folders
- use your Keychain
- accept incoming connections

### Shared folders

**Edit Bot → Harness → Folders** shares folders outside the workspace with one
bot, each as **Read & Write** or **Read Only**, with an optional description of
what it is for. You cannot share the whole disk or Noodle's own storage. Saving
restarts the bot.

Sharing a folder exposes everything in it to the bot's model provider and tools.
FX and OpenCode can also see the names of items in that folder's parent folders.

### Conversations

Bots reach conversations only while Noodle is running, and only the
conversations they belong to. A bot cannot pose as another bot. Attachments
arrive as copies in the bot's workspace, and a bot can attach only files from its
own workspace.

### Sign-ins

Each restricted bot gets a private copy of your harness sign-in. Your other
conversations, skills and settings for that harness are not copied.

- The copies are the same account. Identity, quotas, billing, and revocation are
  shared, and the provider may ask you to sign in again.
- A backup or copy of a bot's folder includes its sign-in. Treat it like a
  password.
- A Codex, Grok Build, Muse Code, or Antigravity bot can use a
  [profile](harness-setup.md#profiles) instead of the system sign-in. A
  restricted bot cannot read other profiles.
- If macOS denies Noodle access to a sign-in kept in the Keychain, the bot fails
  to start with a Keychain-access error; its access is not widened.

## Unrestricted access

An unrestricted bot runs as your Mac user. It can reach files, signed-in
services, and browser sessions beyond its workspace, subject to macOS and tool
permissions.

Turning unrestricted access off does not undo completed actions, stop apps the
bot left running, or revoke macOS privacy permissions. Revoke those in System
Settings.

## Approvals

Noodle does not show approval or question forms in chat. It approves a harness's
tool requests automatically, within the bot's access. Questions that need your
typed answer are declined; Noodle never makes up an answer or consent.

## What restricted access protects

- **Your files stay private.** Personal files, the bot's own configuration, and
  Noodle's storage cannot be read or changed, whatever the model is told.
- **Bots stay apart.** A bot cannot read another bot's files or saved
  conversations.
- **Only genuine harnesses run.** Noodle checks a harness is genuine before
  starting it, and a restricted bot cannot ask for wider access.

## Limitations

- **Allowed files remain writable.** A bot can damage or delete anything in its
  workspace and Read & Write folders. There is no review of edits and no undo.
- **Shared data stays shared.** Members of a conversation can retrieve its
  messages and attachments. Copies already delivered to a workspace are not
  erased when a member is removed. Bots using the same sign-in share that
  account's permissions and billing.
- **Internet access is open.** Anything a bot can read can be sent to a remote
  service, including on your local network. Assigned tools, computers, and
  browsers have their own permissions; the file limits do not apply to what they
  do for a bot.
- **File names are less private than contents.** A bot may be able to see that a
  file exists, and its size and dates, without being able to read it.
- **Some tools fail when restricted.** Things a tool needs outside the allowed
  folders may be unavailable, and a harness update can add new needs. Share the
  folder or make the bot unrestricted.
- **It is not a virtual machine.** There are no CPU, memory, disk, or spending
  limits. A genuine harness can still behave badly.
- **Command arguments are not private.** Other programs on your Mac may be able
  to read them. Keep passwords and keys out of commands.

## Account apps

The **Apps** switch in **Settings → Sandbox** lets a Codex bot use apps connected
to its ChatGPT account, or a Claude Code bot use connectors from Claude.ai. Click
the **Apps** heading or a bot's **apps** status to see the explanation.

Apps are off by default. The setting is separate for each bot and harness:
turning on Codex apps does not turn on Claude connectors when that bot switches
harnesses. Unsupported harnesses show a dash. Changing Apps restarts the bot and
keeps its conversation. Provider or administrator restrictions still apply.

Apps use the permissions granted in the provider account. Turning Apps off does
not disconnect the account, undo completed actions, or erase data already
returned to the conversation. Manage apps and revoke their permissions in
ChatGPT or Claude.ai.

## Connected tools

Assigning a [tool](mcp-connections.md) lets the bot use the permissions you
granted during sign-in, without asking you again for each use. Tool sign-ins
stay in the macOS Keychain and are never written to the bot's files.

A connected tool is a remote service. It receives only workspace files the bot
chooses to send, and it cannot open workspace files or post into a conversation
on its own. Files a tool returns are saved in the workspace without overwriting
existing ones.

Removing an assignment blocks future use; a request already sent may still
finish. Removing the connection deletes its sign-in from this Mac. To revoke the
provider's permission too, use that provider's connected-app settings. An
unrestricted bot's wider access means assignments do not strictly limit it.

## Noodlets

A noodlet a bot writes in [Noodle Applet](../Applet/README.md) does not widen
that bot's access. A noodlet can read only its own files and saved data. It
cannot read your files, another noodlet, or the Keychain; a file reaches it only
when you pick it in a dialog. Removing a bot from a conversation stops its
requests to shared noodlets, though one already running may still finish.

## Files, recording, and computers

Noodle stores chats and bot workspaces on your Mac. Your harness sends work to
its model provider under that provider's account and policies. Imported
attachments and backgrounds are copied into Noodle.

Microphone access is requested when you start a [voice recording](voice-messages.md).
Transcription happens on your Mac; sending shares the audio and transcript with
the chat's bots.

[Noodle Computer](../Computer/README.md) runs Linux workspaces that cannot see
your Mac's folders or clipboard. Bots assigned to the same computer share its
files and services, with separate terminal sessions. Computers can reach your
local network; Shell computers can have networking turned off.

[Documentation](README.md)
