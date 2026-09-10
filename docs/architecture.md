# Noodle architecture

This document turns the supplied Excalidraw sketch into explicit product invariants and implementation boundaries.
The early concept sketch is preserved as [an editable Excalidraw source](noodle-architecture.excalidraw.json) and [a vector export](noodle-architecture.svg), with current Noodle branding. The sketch is historical; the implementation described below is authoritative.

## System flow

```mermaid
flowchart TB
    UI[Noodle Messages UI]
    STORE[Conversation store]
    DRIVERS[Codex and Claude Code native drivers]
    A[Bot A: harness process + session]
    B[Bot B: harness process + session]
    AW[Bot A UUID workspace]
    BW[Bot B UUID workspace]

    UI <--> STORE
    UI -->|notify| A
    UI -->|notify| B
    DRIVERS --> A
    DRIVERS --> B
    A <-->|get_latest / send| STORE
    B <-->|get_latest / send| STORE
    A <--> AW
    B <--> BW
    AW <--> STORE
    BW <--> STORE
```

The number of processes follows the number of bots, not the number of conversations. Two bots participating in two group chats still produce two harness processes. Each process owns one persistent provider session and reads every direct or group conversation that includes its bot UUID.

## Harness discovery

Noodle discovers supported CLI installations, not desktop application names alone. The Codex driver looks for the executable bundled inside `ChatGPT.app` or `Codex.app`, its standalone package, and conventional local binary directories. Claude Code uses Anthropic's native installer link at `~/.local/bin/claude`; FX uses `~/.local/bin/fx`. Grok Build is discovered through the signed host at `~/.grok/bin/grok`, so the main app needs no access to its private configuration. FX remains experimental while its upstream safety-review failure prevents live Messenger verification.

Capability enumeration is harness-specific and private. Codex calls `model/list`; Claude Code exposes standard Fable, Opus, Sonnet and Haiku aliases. FX uses its CLI model catalogue. Grok Build reads model names and per-model reasoning efforts from ACP initialization metadata, and checks the existing login with `authenticate` / `cached_token` without creating a session. These become provider-neutral model and effort records. FX and Grok share a persistent ACP transport with separate session-state files, serialized wakes and unfinished-work markers; Grok reapplies selected model/effort settings after session load.

## Agent workspace and managed skills

Every bot directory is named with an opaque UUID. `AGENTS.md` is the canonical instruction file: its Backstory section is user-authored and its marked runtime section is refreshed by Noodle. `CLAUDE.md` is a relative symlink to the same instructions. Legacy `instructions.md` content is migrated into `AGENTS.md` and the obsolete file is removed. The managed Messenger skill consists of:

- `.agents/skills/messenger/SKILL.md`
- `.agents/skills/messenger/messenger`, a symlink to the bundled `Noodle.app/Contents/Helpers/messenger` executable
- `.agents/managed-skills.json`, recording the managed pack version and paths

On app updates, Noodle refreshes only paths declared in that manifest. Skills created elsewhere under `.agents/skills` remain bot-owned and are not removed.

The harness receives only an inbox-changed notification from Noodle. Codex then runs `messenger --get-latest --inline-images` through its programmatic command bridge; Claude Code runs `messenger --get-latest` with Bash and uses its Read tool for attached image paths. The command returns unread messages across all conversations containing that bot and advances per-conversation offsets in `.noodle/inbox.json`. Legacy `.agents/inbox.json` is a read-only migration fallback; skill/configuration directories remain protected. Runtime startup peeks for unread deliveries off the main thread and queues a notification without consuming them. Linked attachments include an `absolutePath` to the copied conversation-owned payload. The bot replies with `messenger --send`. A bot never receives its own replies back as unread work, and no private Noodle messaging tools are injected into the harness.

## Message and attachment ownership

Conversation metadata, messages, attachment metadata, and copied payloads share one conversation directory. Messages link attachments by UUID; attachment filenames on disk use UUIDs rather than untrusted original names. The original filename and MIME type remain persistent metadata for display. Messenger delivery derives the payload's standardized absolute path at read time, so the path is never guessed or stored as stale metadata.

Message array mutation is guarded by a per-conversation filesystem lock and written atomically, allowing the app and multiple bot processes to post safely into a group transcript. The open app refreshes transcripts so replies written by the Messenger command appear without relaunching.

## Runtime behavior

Sending a user message has two effects:

1. Persist the message and attachments to the conversation.
2. Call `notify` on every participating bot through its existing process, creating the process only if that bot does not already have one.

Each driver translates `notify` into an inbox-changed event with no message body. The harness must run the Messenger CLI, decide what to do, and publish replies through that CLI. This keeps the conversation store authoritative and gives every provider the same retrieval contract. A group chat fans the notification out to participant bot UUIDs; it never creates a group-specific harness process. Notifications coalesce while a bot is already working.

The native `SendNoodleCommandIntent` is another producer of ordinary user messages. Spotlight or Shortcuts resolves a bot or group through an `AppEntity` query, writes the message through the repository, and calls the same runtime `notify` boundary as the in-app composer. App Shortcut parameters are refreshed whenever the conversation catalogue changes.

At application startup, Noodle starts every configured bot and resumes its stored Codex thread or Claude Code session. Configured bots are supervised as desired runtimes: an unexpected process exit, broken XPC connection, failed write, or missing process detected by the health check schedules a replacement with exponential backoff capped at 30 seconds. A macOS wake notification immediately reconciles runtimes instead of waiting for the next retry. If a runtime ended while a turn or inbox notification was pending, the resumed session receives one `runtime-recovered` event so it can safely continue interrupted work without blindly repeating consequential side effects.

Transcript monitoring belongs to the application lifetime rather than a SwiftUI window, so it continues after the window is closed. Filesystem reads, JSON decoding, and transcript comparison happen away from the main actor; unchanged conversation files reuse their in-memory contents, rendered Markdown is cached, attachment lookup is indexed, and the transcript constructs only the rows near the viewport. Scroll geometry stays outside observable state during a gesture and is saved when scrolling becomes idle. Link and attachment previews reserve stable dimensions so lazy layout does not shift as media loads, while attachment thumbnail decoding begins only when its message is visible. A newly observed agent message produces a local macOS notification only when Noodle is not active or has no visible, non-minimized window; clicking it reopens the matching conversation. At application termination, Noodle cancels monitoring and intentionally stops every child process without invoking recovery. Creating or editing a bot starts or restarts only that bot.

## Security

Harness capabilities determine access: Codex supports restricted mode and starts new bots restricted, while Claude Code, FX, Grok Build and Muse Code always use autonomous mode regardless of saved access preferences. Autonomous bots use a signed `NoodleAgentHost.xpc` outside Noodle's App Sandbox. Settings → Security can change a Codex bot's access; harnesses that require autonomous mode show a disabled switch fixed on. The helper has its own process boundary, runs as the current user without App Sandbox or extra entitlements, and accepts only the main app's exact signing identity/team. The app likewise verifies the helper. Autonomous mode uses a vendor-signed Codex or Claude Code executable, a validated UUID workspace, and a provider-specific fixed argument set—never a client-selected shell or arbitrary command.

Autonomous shell turns use Codex `workspaceWrite` and runtime permission requests instead of `externalSandbox`. MCP/browser runtimes are outside this shell boundary and retain their own access controls. Noodle automatically accepts supported command, file, permission, and empty tool-confirmation requests. Filesystem/network grants keep Codex's requested scope and are not persisted by Noodle. Genuine questions are displayed in chat and answered by the user; unsupported request formats fail closed without pausing the bot. Completion, termination, or restriction clears stale questions. Heartbeats use the same autonomous handling.

Each autonomous connection owns a managed process group. Switching access stops that group before launching a replacement; disconnecting cleans it up as well. Restriction is persisted before shutdown, and a failure to confirm termination blocks replacement for that bot. Provider and access modes store separate private session IDs, preserving the shared conversation and workspace. Already completed external actions and detached applications are not undone. The fixed compatibility check proves nested sandbox setup, not browser connectivity or macOS privacy access. See [Security and agent access](security.md) for the exact access disclosure and verification scripts.

Noodle keeps App Sandbox enabled. Attachment import uses the native file importer and the `com.apple.security.files.user-selected.read-only` entitlement. Imported data is copied into the conversation before access ends. Codex requires outgoing client networking and a temporary home-relative read/write exception limited to `/.codex/`; the driver explicitly sets `CODEX_HOME` to that directory so the sandbox does not redirect Codex to an unauthenticated container-local home. Claude discovery adds read-only exceptions for the exact native installer link and version directory. Account access and Claude execution stay in the isolated Agent Host; Noodle has no access to `~/.claude`.

Local notifications use the User Notifications framework and require the user's runtime approval, but no additional entitlement. There is no broad home-directory, Apple Events, device, personal-data, or incoming-network entitlement. The minimal bundled Messenger helper is signed separately without application entitlements and operates only within the bot workspace and conversation roots supplied by the runtime.

See [Storage and Messenger](storage-and-messenger.md) for the on-disk layout and command examples.

---

[Documentation](README.md) · [Noodle](../README.md)
