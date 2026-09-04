# SuperBot

SuperBot is a native macOS messenger and launcher for local coding agents. Bots have stable private workspaces, direct and group conversations, managed skills, conversation-owned attachments, and one long-lived harness process per bot.

## What works now

- Create and rename UUID-backed bots
- Assign Codex or Claude as a bot's harness provider
- Automatically distinguish an installed desktop app, a command-line engine, and an ACP adapter
- Maintain one ACP subprocess per bot, with separate ACP sessions for every direct or group conversation
- Persist direct chats, group chats, unread inbox cursors, and linked attachments
- Install and update the managed Messenger skill without touching a bot's other skills
- Use the `SuperBot` executable as both the macOS application and the agent-local `messenger` command
- Observe Messenger replies in the open conversation without relaunching the app

SuperBot intentionally does not treat an ordinary CLI as ACP-compatible. On the current machine it finds Codex at `/Applications/ChatGPT.app/Contents/Resources/codex`, while the installed Claude desktop app does not expose a Claude CLI. A provider becomes runnable only when its ACP adapter is also discoverable (`codex-acp` or `claude-agent-acp`).

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
│               │   └── messenger -> SuperBot.app/Contents/MacOS/SuperBot
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
```

The command infers the bot UUID and SuperBot repository root from its symlink location. Results are JSON so any harness can consume them without provider-specific parsing.

## Build, launch, and test

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

The signed application is written to `.build/SuperBot.app`. To install it in `/Applications`:

```sh
scripts/install-app.sh
```

Set `SUPERBOT_SIGNING_IDENTITY` when a non-ad-hoc signing identity is required.

## Security boundary

The finished app has exactly two sandbox entitlements:

- App Sandbox
- User-selected file read access, used only to import attachments

There is no broad filesystem, automation, camera, microphone, contacts, incoming network, or personal-data entitlement. ACP subprocess execution remains gated on a separately detected adapter instead of silently running an incompatible binary.

See [docs/architecture.md](docs/architecture.md) for the process and data flow.
