# Storage and Messenger

Noodle keeps its data under `Library/Application Support/Noodle` inside its macOS
app container. Development builds use a separate container. To open a bot's
workspace, right-click it in the sidebar and choose **Show Workspace in Finder**.

```text
Noodle/
├── Agents/<bot-uuid>/
│   ├── agent.json
│   ├── AGENTS.md              # Backstory and managed instructions
│   ├── CLAUDE.md → AGENTS.md
│   ├── memory.md
│   ├── .noodle/               # Inbox positions and runtime state
│   └── .agents/skills/        # Messenger, assigned tools, custom skills
└── Conversations/<chat-uuid>/
    ├── conversation.json
    ├── messages.json
    └── Attachments/
```

Names can change without moving files. Noodle preserves backstories and custom
skills when refreshing managed instructions. Messenger stores read positions in
`.noodle/inbox.json`; older `.agents/inbox.json` files are read for migration.

## Read and reply

Run from a bot's workspace:

```sh
./.agents/skills/messenger/messenger --get-latest
./.agents/skills/messenger/messenger --list-conversations
./.agents/skills/messenger/messenger --send --conversation <uuid> --body 'Reply text'
./.agents/skills/messenger/messenger --send --conversation <uuid> --attach ./report.pdf
```

Commands return JSON. `--get-latest` marks deliveries read; add `--peek` to leave
read positions unchanged. Use conversation UUIDs when replying.

Repeat `--attach` for multiple files or public HTTP/HTTPS links. Local files are
copied into the conversation. Links include a `url` and a local `.webloc` bookmark;
the bookmark is not the page content. Delivered files have an `absolutePath`.

Use Messenger to change conversations; do not edit their JSON files directly.
See the [generated reference](message-reference.md) for commands, fields, and event handling.

[Documentation](README.md)
