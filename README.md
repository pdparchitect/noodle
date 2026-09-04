# SuperBot

SuperBot is a native macOS messenger and launcher for local coding agents. Bots have stable private workspaces, direct and group conversations, managed skills, conversation-owned attachments, and one long-lived harness process per bot.

## What works now

- Create and edit UUID-backed bots
- Explicitly assign one of the installed, supported harnesses to each bot
- Read the live model catalogue and model-specific effort levels from Codex
- Maintain one persistent Codex App Server process and thread per bot
- Start every configured bot with SuperBot and stop every bot when SuperBot terminates
- Notify bots without copying message bodies into the harness event
- Let Codex read and reply through the bundled Messenger CLI
- Persist direct chats, group chats, unread inbox cursors, and linked attachments
- Accept any regular file attachment and preview Quick Look-compatible files, including PDFs, in place
- Install and update the managed Messenger skill without touching a bot's other skills
- Bundle a separately signed, minimal `messenger` command for every harness
- Expose a native “Send SuperBot Command” App Intent to Spotlight and Shortcuts
- Observe Messenger replies in the open conversation without relaunching the app
- Show native macOS notifications for new bot replies while SuperBot is unfocused, hidden, minimized, or has no open window

Codex is the first implemented harness. SuperBot finds the Codex executable bundled with ChatGPT or Codex, speaks its native App Server protocol internally, and keeps that implementation behind the provider-neutral `start`, `stop`, and `notify` runtime boundary. ACP is not used.

## Durable layout

In the signed sandboxed app, macOS places this hierarchy inside SuperBot's Application Support container:

```text
Library/Application Support/SuperBot/
├── Agents/
│   └── <agent-uuid>/
│       ├── agent.json
│       ├── instructions.md
│       ├── memory.md
│       ├── AGENTS.md
│       ├── CLAUDE.md -> AGENTS.md
│       └── .agents/
│           ├── inbox.json
│           ├── managed-skills.json
│           └── skills/
│               ├── messenger/
│               │   ├── SKILL.md
│               │   └── messenger -> SuperBot.app/Contents/Helpers/messenger
│               └── <bot-owned-skills>/
└── Conversations/
    └── <conversation-uuid>/
        ├── conversation.json
        ├── messages.json
        └── Attachments/
            ├── <attachment-uuid>.json
            └── <attachment-uuid>.<extension>
```

Display names never participate in filesystem paths. Managed core-skill files are versioned explicitly; custom bot skills are outside that managed set and are preserved during synchronization.

## Messenger command

From inside a bot workspace:

```sh
./.agents/skills/messenger/messenger --get-latest
./.agents/skills/messenger/messenger --get-latest --peek
./.agents/skills/messenger/messenger --list-conversations
./.agents/skills/messenger/messenger --send --conversation <uuid> --body "Reply text"
./.agents/skills/messenger/messenger --send --conversation <uuid> --body "Files attached" --attach ./report.pdf --attach ./chart.png
```

The command can infer the bot UUID and SuperBot repository root from its symlink location or from the private runtime environment. Results are JSON so harnesses can consume them without provider-specific parsing. Every delivered attachment includes its absolute copied-file path so a harness can open it directly. A bot sends files with a repeatable `--attach <file-path>` option; relative paths resolve from its workspace, and SuperBot copies each file into conversation-owned storage before linking it to the reply. Reply text is optional when at least one attachment is supplied. Codex runs this CLI through its programmatic command bridge; it does not receive private SuperBot messaging tools.

## Quick send with Spotlight and Shortcuts

Install and launch the signed app once, then press Command-Space and search for **Send SuperBot Command**. Choose any current bot or group, enter the command, and macOS delivers it without bringing SuperBot to the foreground. The same action is available in the Shortcuts app for custom keyboard shortcuts, menu-bar shortcuts, and automations.

Bot and group suggestions update after creation, rename, membership changes, and deletion. An App Intent command follows the same path as the composer: SuperBot persists a normal user message and notifies every participating bot.

SuperBot asks for notification permission on first launch. Notifications use the bot name as the title, include the group name when relevant, and open the corresponding conversation when clicked. They are suppressed while a visible SuperBot window is active.

## Build, launch, and test

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

The signed application is written to `.build/SuperBot.app`. To install it in `/Applications` and register its App Intent:

```sh
scripts/install-app.sh
```

The build automatically uses the first installed Apple Development identity so macOS can index App Intents. Set `SUPERBOT_SIGNING_IDENTITY` to override that choice, or set it to `-` explicitly for an ad-hoc build.

## Security boundary

The finished app keeps App Sandbox enabled with these narrowly scoped entitlements:

- App Sandbox
- User-selected file read access, used only to import attachments
- Outgoing network client access, required by Codex
- A home-relative read/write exception restricted to `~/.codex/`, allowing the Codex child to use the user's existing login and persistent thread state

There is no broad home-folder, automation, camera, microphone, contacts, incoming-network, or personal-data entitlement. SuperBot explicitly points Codex at `~/.codex` but never copies or parses the credentials itself. The bundled Messenger helper is separately signed without the application entitlements.

See [docs/architecture.md](docs/architecture.md) for the process and data flow.
