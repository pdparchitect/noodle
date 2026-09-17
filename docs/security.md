# Agent access and privacy

## Choose a bot's access

| Harness | Access in Noodle |
| --- | --- |
| Codex, Claude Code, FX, Grok Build, Muse Code, Apple Intelligence | Restricted by default; unrestricted access is optional |

Change any bot's access in **Settings → Sandbox**. Click the **Unrestricted**
heading or a bot's **restricted** or **unrestricted** label to see what that mode
allows. All harnesses use the bot's
saved access preference. Previous required Claude/FX/Grok/Muse grants do not
override that preference. Editing `agent.json` alone never grants unrestricted access.

## How restricted mode works

Noodle uses two separate macOS boundaries. The app stays in App Sandbox. A signed
launch broker, `NoodleAgentHost.xpc`, runs outside that app sandbox and validates
the calling app, harness executable, and bot workspace. For restricted runs it
applies a deny-by-default Seatbelt policy before executing the harness. The
policy permits fixed paths and system services derived by the host; callers
cannot supply their own permissions. If validation or policy application fails,
startup fails instead of falling back to unrestricted access.

Shell commands and other child processes inherit the harness's OS restrictions.
An automatically accepted tool approval cannot add filesystem permissions to
that policy. The restrictions therefore apply even when a model issues an
unexpected command or follows misleading instructions.

Each restricted bot can read its own `Agents/<uuid>` package and write only
inside that package's `workspace`. Its `agent.json`, layout metadata, and
Noodle-owned `runtime` remain read-only. Other bots' packages, the shared
conversation store, Noodle preferences, and unrelated personal files are outside
the content-read and write boundary. System libraries, the signed app/harness
installation, and required system services remain available.

Conversation access goes through the Messenger CLI and an app-side broker.
Noodle must be running. The broker derives bot identity from the registered
workspace and a per-bot session token, then checks conversation membership. A CLI
flag, forged bot ID, or edited skill cannot grant another bot's access. The CLI
has no direct conversation-file fallback. Attachment reads return copies under
`workspace/.noodle/messenger-attachments`; local attachment sends can import only
regular files from the caller's workspace, without following symlinks.

Cloud harnesses have a private home at `workspace/.noodle/home`. Codex, Claude, FX, Grok,
and Muse store their own configuration, sessions, and caches there; Muse's data,
state, and runtime directories remain under `workspace/.noodle/muse`. The trusted
Agent Host seeds only login material from the existing provider sign-in. It does
not copy standalone conversations, global skills, hooks, or MCP configuration.
FX also receives its selected provider/model settings. Native installations stay
read-only.

For Claude, FX, and Muse Keychain-backed sign-ins, the host requests only the exact
provider credential item, without prompting. The harness receives a private file
credential store and has no access to the login Keychain or shared account
folder. If macOS denies that item, startup fails with a Keychain-access error;
it does not widen the sandbox. FX's TLS implementation still reads the system
certificate store at `/Library/Keychains/System.keychain`.

Each bot keeps credentials it refreshes. The host replaces them when the source
login changes, and never writes the bot's credentials back to the shared login.
Bot-package backups and copies now include these private login files and should
be treated as credentials. These are copies of the same provider login, so provider-side identity, quotas,
and revocation remain shared; they are not separate provider accounts. Provider
refresh-token rotation can require signing in again. Existing native Codex
sessions stored in the former shared account may need a fresh model context;
Noodle's conversation history remains available through Messenger.

Workspace mailboxes, attachment copies, and managed instructions/skills use
anchored directory handles. Replacing a writable parent directory with a symlink
cannot redirect a privileged app operation into another bot's files.

FX uses ACP ask mode and Noodle grants only the
offered allow-once action for the current session. Grok uses a dedicated
`--no-leader` process with its inner sandbox disabled because Agent Host has
already applied the mandatory outer policy. These tool approvals cannot widen
the OS sandbox. Cancelled turns and stale-session requests are denied.

Muse starts its verified native binary directly, without the self-updating shell
launcher. Agent Host applies the outer sandbox before running `serve`; Muse's
inner shell sandbox is disabled to avoid nesting Seatbelt policies. MSP tool
approvals select only the offered once-only choice for the current session and
stage, and cannot grant new filesystem access.

Claude uses its normal stream-json runtime and tools. Agent Host explicitly sets
`sandbox.enabled=false` for restricted launches: Noodle's outer policy covers
native Read/Edit/Write tools, Bash, and child processes. `CLAUDE_CONFIG_DIR` points
to the bot's private `.claude` directory, and `CLAUDE_CODE_TMPDIR` keeps Claude's
internal temporary files inside the workspace. The host seeds only `claudeAiOauth`
from the standard `Claude Code-credentials` Keychain item for the current user,
or the native `.claude/.credentials.json` fallback when that item is absent.
Settings, hooks, MCP logins, and global history are not imported. Restricted and
unrestricted sessions have separate pointers; switching access does not resume the
other mode's native session.

Unrestricted mode runs as your
Mac user outside Noodle's app sandbox. It can reach files, signed-in services, and
browser sessions beyond the bot's workspace, subject to macOS and tool permissions.
Noodle accepts supported tool approvals automatically under the bot's saved
access mode. There are no per-action approval or question forms in chat.
Structured runtime question requests receive an empty response immediately.
Unknown requests and tool forms requiring user-entered data are declined
without inventing answers or consent.

Changing access restarts the bot. Turning unrestricted access off does not undo
completed actions, stop detached applications, or revoke macOS privacy permissions.
Revoke those separately in System Settings.

## Strengths

- **Enforced by macOS:** file restrictions apply before harness startup and to
  its child processes, independently of the model's instructions or approvals.
- **Protects files outside the allowed roots:** direct writes to bot
  configuration, Noodle runtime state, and unrelated personal files are denied.
  Ordinary link, rename, and replacement attempts do not grant access outside
  the policy. Unrelated personal file contents are also denied.
- **Per-bot storage and authorized conversations:** other bots’ files and raw
  conversation JSON are denied. The app checks membership and tool assignments
  before releasing data or performing a request.
- **A controlled launch boundary:** the host verifies executable identity and
  accepts only supported launch options. Restricted runs cannot request a wider
  policy, and enabling another restricted harness does not require broader app
  entitlements.

## Limitations

- **Allowed files remain writable.** A bot can damage or delete data inside its
  writable workspace, including its private harness storage. The
  sandbox does not validate the meaning of edits or provide rollback.
- **Authorized data is still shared.** Members of a conversation can retrieve
  its messages and attachments through Messenger. Copies already delivered to
  a workspace are not erased when membership is removed. Bots using the same
  provider login share that provider account's permissions and billing.
- **Cloud harness networking is open outbound.** Codex, Claude Code, FX, Grok Build, and Muse
  Code are not limited to a list of model-provider domains. Readable data can be
  sent to remote services, and the policy does not block outbound LAN access.
  Connections to localhost are allowed. The current profiles deny starting
  listening sockets, including localhost servers.
  Restricted Apple denies direct outbound networking and runs its default
  model on device. Separately assigned tools and computers have their own
  permissions; the local filesystem policy does not restrict actions they
  perform on a bot's behalf.
- **File metadata is less restricted than contents.** The profiles generally
  allow metadata queries, so file existence and attributes can be visible even
  when contents cannot be read. FX also needs exact directory-entry reads along
  its workspace ancestors for native skill discovery; these can expose sibling
  names, but do not grant sibling file contents.
- **Some tools will fail inside the boundary.** Dependencies, caches, global
  skills, services, or files outside the allowed paths may be unavailable.
  Harness updates can introduce new requirements. A tool approval does not fix
  an OS permission denial; broader access requires the bot's unrestricted setting.
- **This is a native process sandbox.** It does not provide a separate operating
  system or set CPU, memory, disk-use, or model-spending quotas. It relies on the
  macOS sandbox and Noodle's trusted launch and tool brokers. Signature checks
  identify code; they do not establish that its behavior is harmless.
- **Process arguments are not confidential.** Restricted cloud and Apple
  profiles do not reliably prevent reading another same-user process's command
  arguments on macOS 27. Keep credentials out of command arguments; workspace
  filesystem isolation does not protect them.

## Account apps

The **Apps** switch in **Settings → Sandbox** lets a Codex bot use apps connected
to its ChatGPT account, or a Claude Code bot use connectors from Claude.ai. Click
the **Apps** heading or a bot's **apps** status to see the explanation.

Apps are off by default, including for existing bots. The preference is saved
separately for each bot and harness: enabling Codex apps does not enable Claude
connectors when that bot switches harnesses. Unsupported harnesses show a dash.
Unrestricted access and Noodle-assigned tools have separate settings.

Changing Apps restarts the bot, retaining its conversation. Revocation is saved
before shutdown; a grant is saved only once the previous runtime has stopped.
Codex receives an explicit `apps` feature override at launch; Claude receives
`disableClaudeAiConnectors` in its launch settings. Noodle does not edit either
harness's global configuration. Provider or administrator restrictions still
apply when Apps is on. Setup and model-discovery probes run with apps disabled.

This switch controls those account apps, not every remote tool or network
request. Apps use the permissions granted in the provider account. Turning Apps
off does not disconnect the account, undo completed actions, or erase data
already returned to the conversation. Manage individual apps and revoke their
account permissions in ChatGPT or Claude.ai.

## Connected tools

Assigning a tool lets the bot use the permissions you granted during provider
sign-in. Noodle does not ask again for each tool call. OAuth credentials stay in
the macOS Keychain and are not written to bot skills or request files.

The MCP CLI saves binary results under `workspace/.noodle/mcp-attachments` without
overwriting existing files. Its `@file` inputs can read only regular workspace
files, rejecting symlinks, hard links, and traversal. Resource links require an
explicit read; returned links are never followed automatically.

Removing an assignment blocks future calls; a call already sent may still finish.
Removing the connection deletes its local credentials. To revoke the provider's
grant too, use that provider's connected-app settings. An unrestricted bot's wider
system access means workspace assignment checks are not a hard isolation boundary.

Applet requests are checked against the current bot session and conversation
membership before dispatch, again after companion startup waits, and before any
result is released. Removing and re-adding a bot does not reactivate requests
from its previous session. Revoked callers receive neither success payloads nor
provider diagnostics. An operation already dispatched to Applet may still finish;
these checks do not undo its effects or erase files previously delivered.

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
and a fixed set of launch options. Restricted Codex, Claude Code, FX, Grok Build, Muse Code, and Apple receive their filesystem
policy before the harness executable starts; failure to apply it prevents
startup. The host accepts no caller-supplied sandbox profile, arbitrary command,
or writable roots. Unrestricted harnesses use the separate authorized launch path.
The host runs as the current user, never root. App and helper entitlements are
unchanged by bot isolation.

The built-in `NoodleAppleAgent` is verified against this app's exact helper path,
signing team, and helper identifier. It has no extra entitlements and does not
inherit the app sandbox. Agent Host applies its own deny-by-default policy before
execution: system and own-bot package reads, workspace writes,
read-only model-availability and global preferences, and the Apple model-manager
service. Outbound network and unrelated user files are denied. Its initial
Default model runs on device through Foundation Models. The existing per-bot
unrestricted setting enables broader user-level access through the same authorized
launch path as other harnesses. The app's entitlements remain unchanged.

On macOS 27, `IOSurfaceRootUserClient` access permits image-buffer allocation.
The `com.apple.MTLCompilerService` Mach service and `AGXDeviceUserClient` GPU
interface permit Core Image to render the attachment pixels and MLX to run
local inference. Metal can read and write only the helper's
`com.pdparchitect.noodle.apple-agent` subdirectory in the Darwin user cache;
other applications' caches are not granted. This is needed for macOS 27's
binary-archive bookkeeping. Selecting an imported MLX model adds read-only access to that
model's private folder. Imported
weights receive no executable-mapping grant. Model imports copy regular data
files through the app's existing user-selected read access; the helper cannot
download weights or change the model library in restricted mode. MLX code and
Metal shaders ship inside the signed app, and resource bundles are signed before
the app is sealed. The helper has no additional code-signing entitlements.
Current image attachments can be supplied directly to a capable Apple model;
private cloud inference is not enabled.

Sparkle's signed installer runs outside the sandbox to replace the app during updates.

The policies are implemented in
[`RestrictedAgentSandbox.swift`](../Sources/NoodleCore/RestrictedAgentSandbox.swift)
and [`AppleHarness.swift`](../Sources/NoodleCore/AppleHarness.swift). Login seeding is
in [`RestrictedHarnessStorage.swift`](../Sources/NoodleCore/RestrictedHarnessStorage.swift),
conversation authorization is in [`MessengerBridge.swift`](../Sources/NoodleCore/MessengerBridge.swift),
and workspace I/O is anchored by [`WorkspaceMailbox.swift`](../Sources/NoodleCore/WorkspaceMailbox.swift), with launch
enforcement in [`NoodleAgentHost`](../Sources/NoodleAgentHost/main.swift).
[Development](development.md) describes the real-process filesystem boundary
tests, offline initialization checks, opt-in live Messenger/resume checks, and
signed-bundle verification. Those checks exercise specific allowed and denied
operations; they are not an exhaustive security audit. See
[architecture](architecture.md) for the surrounding process boundaries.

[Documentation](README.md)
