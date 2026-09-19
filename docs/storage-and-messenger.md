# Storage and Messenger

Noodle keeps its data under `Library/Application Support/Noodle` inside its macOS
app container. Development builds use a separate container. To open a bot's
workspace, right-click it in the sidebar and choose **Show Workspace in Finder**.

```text
Noodle/
├── Agents/<bot-uuid>/
│   ├── agent.json             # Bot settings, private Backstory, shared folders
│   ├── .noodle-storage.json   # Storage layout version
│   ├── runtime/              # Session pointers and unfinished-turn markers
│   └── workspace/            # Harness working directory
│       ├── AGENTS.md          # Fully generated Backstory and runtime guidance
│       ├── CLAUDE.md → AGENTS.md
│       ├── memory.md
│       ├── preferences.md
│       ├── .noodle/           # Inbox positions, diagnostics, tool bridges
│       └── .agents/skills/    # Messenger, assigned tools, custom skills
└── Conversations/<chat-uuid>/
    ├── conversation.json
    ├── messages.json
    └── Attachments/
```

Names can change without moving files. Backstory is stored in `agent.json` and
edited through Noodle. Changes to generated `AGENTS.md` or `CLAUDE.md` are overwritten
on refresh. Keep standing preferences in `preferences.md` and durable context in
`memory.md`; Noodle preserves those files and custom skills. Messenger stores read positions in
`.noodle/inbox.json`; older `.agents/inbox.json` files are read for migration.

On first launch after upgrading, Noodle moves flat agent workspaces into this
layout before starting any bots. Migration preserves UUIDs, user files, inbox
positions, and all harness session pointers. Existing user folders named
`workspace` or `runtime` move inside the new workspace. An interrupted migration
resumes on the next launch; conflicts stop migration without overwriting files.
Absolute paths in custom scripts or external links may need updating.

Noodle 0.14.0 also imports Backstory from older workspace Markdown into `agent.json`
before regenerating instructions. A saved `backstory` string marks this migration
complete, even when empty. If the old source is missing or its markers are damaged,
startup reports the problem and leaves the source intact for recovery. Once migrated,
generated Markdown can be rebuilt without recovering Backstory from it.

To carry an agent's core to another installation, quit Noodle and copy the entire
`Agents/<bot-uuid>` package, including hidden files and symlinks, into the other
installation's `Agents` directory. Use Noodle 0.14.0 or later for packages with
Backstory in `agent.json`; earlier releases do not preserve that field. Keep the UUID folder name. Noodle refreshes its
managed tool links on launch. Install and sign in to the selected harness and
authorize unrestricted access if needed. Chats and attachments remain in
`Conversations`; tool/computer assignments and credentials are separate.
Session pointers do not contain the harness's full history. Muse starts a new
session after a workspace move and recovers context from Noodle's chat history.

## Read and reply

Run from a bot's `workspace` directory:

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
