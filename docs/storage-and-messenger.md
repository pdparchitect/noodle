# Storage and Messenger

Codex is the first implemented harness. SuperBot finds the Codex executable bundled with ChatGPT or Codex, speaks its native App Server protocol internally, and keeps that implementation behind the provider-neutral `start`, `stop`, and `notify` runtime boundary. ACP is not used.

## Durable layout

In the signed sandboxed app, macOS places this hierarchy inside SuperBot's Application Support container:

```text
Library/Application Support/SuperBot/
├── conversation-state.json (durable unread conversation markers)
├── Agents/
│   └── <agent-uuid>/
│       ├── agent.json
│       ├── memory.md
│       ├── AGENTS.md (editable backstory + managed runtime guidance)
│       ├── CLAUDE.md -> AGENTS.md
│       ├── .superbot/inbox.json (mutable message/reaction read positions)
│       └── .agents/
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

`AGENTS.md` is the single source of truth for bot instructions. SuperBot preserves the user-authored Backstory section while refreshing its marked runtime section. Older `instructions.md` content is migrated into the Backstory section and the obsolete file is removed.

## Inbox state and migration

Messenger stores mutable inbox cursors in the bot's `.superbot/inbox.json`, inside its already-writable workspace. Older `.agents/inbox.json` cursors are read as a migration fallback and left untouched; subsequent consumption writes the new location. This keeps Codex's protected skills directory read-only without requiring elevated access just to read messages.

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

See [Architecture](architecture.md) for the process and data flow.


---

[Documentation](README.md) · [SuperBot](../README.md)

