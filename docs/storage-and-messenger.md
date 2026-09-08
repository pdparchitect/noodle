# Storage and Messenger

Noodle has native drivers for Codex and Claude Code behind the same provider-neutral `start`, `stop`, and `notify` runtime boundary. Codex uses App Server; Claude Code uses its persistent stream-json input/output mode. ACP is not used.

## Durable layout

In the signed sandboxed app, macOS places this hierarchy inside Noodle's Application Support container:

```text
Library/Application Support/Noodle/
├── conversation-state.json (durable unread conversation markers)
├── Agents/
│   └── <agent-uuid>/
│       ├── agent.json
│       ├── memory.md
│       ├── AGENTS.md (editable backstory + managed runtime guidance)
│       ├── CLAUDE.md -> AGENTS.md
│       ├── .noodle/inbox.json (mutable message/reaction read positions)
│       └── .agents/
│           ├── managed-skills.json
│           └── skills/
│               ├── messenger/
│               │   ├── SKILL.md
│               │   └── messenger -> Noodle.app/Contents/Helpers/messenger
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

`AGENTS.md` is the single source of truth for bot instructions. Noodle preserves the user-authored Backstory section while refreshing its marked runtime section. Older `instructions.md` content is migrated into the Backstory section and the obsolete file is removed.

## Inbox state and migration

Messenger stores mutable inbox cursors in the bot's `.noodle/inbox.json`, inside its already-writable workspace. Older `.agents/inbox.json` cursors are read as a migration fallback and left untouched; subsequent consumption writes the new location. This keeps Codex's protected skills directory read-only without requiring elevated access just to read messages.

## Messenger command

See the generated [Messages and events reference](message-reference.md) for all wake events, messages, group notices, reactions, effects, delivery fields, and CLI commands. Its source is the same catalogue used for agent instructions and CLI help.

From inside a bot workspace:

```sh
./.agents/skills/messenger/messenger --get-latest
./.agents/skills/messenger/messenger --get-latest --peek
./.agents/skills/messenger/messenger --list-conversations
./.agents/skills/messenger/messenger --send --conversation <uuid> --body "Reply text"
./.agents/skills/messenger/messenger --send --conversation <uuid> --body "Files attached" --attach ./report.pdf --attach ./chart.png
```

The command can infer the bot UUID and Noodle repository root from its symlink location or from the private runtime environment. Results are JSON so harnesses can consume them without provider-specific parsing. The repeatable `--attach <file-path-or-url>` option accepts local paths and `file:///` URLs as files, and public HTTP/HTTPS URLs as link attachments. Files are copied into conversation-owned storage. Links are stored as small `.webloc` bookmarks, with a structured `url` in the delivery and a best-effort preview card in chat; no page content is downloaded at send time. Every delivered attachment includes its `absolutePath`; for links this points to the bookmark, not the webpage. Relative file paths resolve from the current working directory. Reply text is optional when at least one attachment is supplied. See the generated reference for validation rules and the complete attachment fields. Codex runs this CLI through its programmatic command bridge; Claude Code runs it with its Bash tool and opens image paths with its Read tool. Neither harness receives private Noodle messaging tools.

Agents can also trigger temporary [chat effects](chat-effects.md), starting with `--effect confetti --conversation <uuid>`. Use `--list-effects` to discover supported effects.

See [Architecture](architecture.md) for the process and data flow.


---

[Documentation](README.md) · [Noodle](../README.md)
