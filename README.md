# SuperBot

SuperBot is a native macOS messenger and launcher for local coding agents. Bots have stable private workspaces, direct and group conversations, managed skills, conversation-owned attachments, and one long-lived harness process per bot.

## What works now

- Create and edit UUID-backed bots
- Give each bot an editable backstory stored canonically in `AGENTS.md`
- Explicitly assign one of the installed, supported harnesses to each bot
- Read the live model catalogue and model-specific effort levels from Codex
- Maintain one persistent Codex App Server process and thread per bot
- Start every configured bot with SuperBot and stop every bot when SuperBot terminates
- Notify bots without copying message bodies into the harness event
- Let Codex read and reply through the bundled Messenger CLI
- Persist direct chats, group chats, unread inbox cursors, and linked attachments
- Show durable unread indicators for conversations with unseen bot replies
- Accept any regular file attachment, show selectable inline thumbnails outside the message bubble, and open Quick Look-compatible files—including PDFs—with Space or a double-click
- Install and update the managed Messenger skill without touching a bot's other skills
- Bundle a separately signed, minimal `messenger` command for every harness
- Expose a native “Send SuperBot Command” App Intent to Spotlight and Shortcuts
- Observe Messenger replies in the open conversation without relaunching the app
- Show native macOS notifications with the sending bot's avatar while SuperBot is unfocused, hidden, minimized, or has no open window
- Check for signed updates hosted entirely on GitHub and install/relaunch without interrupting active agents
- Wake idle agents with configurable inactivity heartbeats, enabled by default after 30 minutes

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

## Agent heartbeats

**Settings → Heartbeats** enables or disables inactivity wake-ups globally or for individual bots and sets the idle interval (30 minutes by default, configurable from 1 minute to 24 hours). Each bot has its own timer. Incoming notifications, outgoing messages and reactions, active harness work, and completion of a turn restart that timer. Merely viewing a conversation or polling for messages does not reset it.

After a full quiet interval, SuperBot delivers a distinct `<superbot-event type="heartbeat" />` to a ready, idle agent using the same harness turn mechanism as message notifications. It never interrupts an active turn, queues stale heartbeats behind messages, or starts offline/failed bots. Normal incoming messages still take priority. A heartbeat that finishes without a reply starts another full idle interval; waking the Mac after a long sleep produces at most one overdue heartbeat per idle bot, not a backlog of turns.

The agent checks Messenger, then reviews its existing Backstory, memory, and previously assigned work for useful authorized follow-ups. Heartbeats do not grant new authority. Agents are instructed not to invent work or send routine heartbeat acknowledgements. Each heartbeat may consume model tokens even when it produces no chat message.

Preferences persist across launches. Timers start fresh when agents reconnect, when the global interval/switch changes, or when a bot's individual switch changes. Heartbeats run only while SuperBot is running; they do not launch the app or wake a sleeping Mac. No additional sandbox entitlement is needed.

## Optional extended agent access

**Settings → Security** offers an explicit per-bot opt-in. All existing and new bots remain **Restricted** by default. Restricted agents continue to inherit SuperBot's App Sandbox. **Extended** agents run through the separately signed, hardened `SuperBotAgentHost.xpc`, outside that sandbox, as the current user (never root). This removes the inherited sandbox that prevented the browser-control runtime from applying its own sandbox. Browser/computer control still depends on the installed integration and macOS privacy permissions; a successful helper check does not prove browser access. Startup failures show their error and a **Retry Startup** button in Security. Starting a runtime checks for unread messages without consuming them, recovering pending notifications after a restart.

Enabling extended access displays a warning: tools may access files and signed-in browser sessions beyond the bot workspace. Connected MCP tools have their own permissions and may run outside Codex's shell sandbox; this is not a guarantee of approval before every action. Codex shell turns use `workspaceWrite` (the bot workspace and SuperBot's conversation store), restricted network access, and `on-request` approvals. The app renders command/file/permission requests and user questions in chat, with an orange sidebar indicator. Grants are single-command or current-turn only. Requests expire with their runtime/turn, and unsupported requests cannot be accepted with fabricated consent. Unattended heartbeats never approve requests.

Changing access stops the managed runtime process group before restarting. Restricted and extended modes use separate persisted Codex sessions; the conversation and bot workspace remain unchanged. Turning extended access off persists revocation first. Failed termination prevents an automatic replacement process. External applications already opened, detached services, and previously completed side effects are not undone by revocation. OS privacy grants must be revoked separately in System Settings.

The XPC service accepts only SuperBot's exact signed identity and signing team, and SuperBot verifies the helper's identity. It exposes no arbitrary executable/arguments/environment endpoint; it accepts a bot UUID and validates its existing workspace plus a vendor-signed OpenAI Codex executable bundled in `/Applications/ChatGPT.app` or `/Applications/Codex.app`. PATH-installed Codex remains supported in restricted mode only. Connections closing stop their managed process groups. **Test Extended Runtime**, under **Settings → Dev** in debug builds only, runs a fixed `sandbox-exec … /usr/bin/true` probe, without enabling a bot, invoking a model, or opening a browser. Smoke tests separately verify that a Foundation-launched helper starts in its own process group.

Settings are ordered **Harnesses → Heartbeats → Security → Updates → Dev**. The entire Dev tab is compiled out of release builds. Use `SUPERBOT_BUILD_CONFIGURATION=debug scripts/build-app.sh` for a local development build.

Messenger stores mutable inbox cursors in the bot's `.superbot/inbox.json`, inside its already-writable workspace. Older `.agents/inbox.json` cursors are read as a migration fallback and left untouched; subsequent consumption writes the new location. This keeps Codex's protected skills directory read-only without requiring elevated access just to read messages.

Plain MCP confirmation forms with no input fields (such as a browser destination prompt) show **Allow** and **Decline**. The app sends acceptance only after the user's click, with an empty response object; it does not fabricate field values or claim the tool's grant lasts only one command. URL/sign-in flows, forms requesting data, and unknown schema constraints remain unsupported and cannot be accepted.

Groups can contain **one or more bots**. New Group and Group Info share an **Add Bots** search picker and a grid of selected avatars with individual remove controls. Saving an empty group is not allowed; removing a member does not delete the bot or conversation history.

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

## Releases

The root `VERSION` file is the canonical stable application version (`X.Y.Z`). Swift Package Manager describes the package and deployment target, but it does not provide a macOS app marketing version. Starting with the updater bootstrap, the build copies `VERSION` into both `CFBundleShortVersionString` and `CFBundleVersion`, so local builds and CI releases use the same ordering. Increase it for every release; never reuse a published version. `SUPERBOT_BUILD_NUMBER` is a local-testing override only; release packaging always uses `VERSION`.

To publish a release, update `VERSION`, commit the change, and run:

```sh
scripts/create-release-tag.sh
```

The script creates and pushes a matching `vX.Y.Z` tag. GitHub Actions runs the tests, imports the dedicated Developer ID Application identity into an ephemeral keychain, signs the app and every embedded executable, submits the archive to Apple's notary service, staples the ticket, and verifies Gatekeeper acceptance. Sparkle then signs the final ZIP and generates a signed `appcast.xml`. The release stays a draft until its ZIP, checksum, and appcast have all uploaded, then becomes the latest GitHub release.

The release workflow reads signing material only from encrypted GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

The `.p12` secret is used only for code signing; the App Store Connect API key is used only for notarization. The dedicated Sparkle Ed25519 private key signs update archives and feeds; only its public key is embedded in the app. No certificate, private key, password, or notarization credential belongs in the repository. Temporary CI signing material is removed on success or failure.

### In-app updates

Use **SuperBot → Check for Updates…** or **Settings → Updates**. Automatic daily checks are enabled by default. Automatic download/installation is a separate opt-in setting. Sparkle provides release prompts, progress, signature validation, installation, and relaunch. Restarting is postponed while an agent is starting/working, a message or attachment is unsent, an editor is open, or a shared item is being delivered. An additional termination check protects a resumed installation as well.

The app fetches `https://github.com/pdparchitect/superbot/releases/latest/download/appcast.xml`; its enclosures point to versioned ZIP assets in the same public GitHub repository. There is no separate server, GitHub Pages site, access token in the app, or custom download service. Only publish stable releases as “latest.” The previous release remains available while CI builds and uploads the next one.

Sparkle is pinned to 2.9.4 in `Package.swift` and `Package.resolved`, from [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle). Its complete upstream licence is copied into the signed app's Resources. To regenerate a feed locally without exporting the dedicated Keychain key, use the bundled `generate_appcast --account com.pdparchitect.superbot` tool. Back up the signing key securely: losing it prevents straightforward updates for existing installations. Never rotate the embedded public key without following Sparkle's key-transition procedure.

## Security boundary

The finished app keeps App Sandbox enabled with these narrowly scoped entitlements:

- App Sandbox
- User-selected file read access, used only to import attachments
- Outgoing network client access, required by Codex
- A home-relative read/write exception restricted to `~/.codex/`, allowing the Codex child to use the user's existing login and persistent thread state
- The existing team-scoped sharing app group, shared only with SuperBot's share extension
- Exactly two update-installer IPC names: `com.pdparchitect.superbot-spks` and `com.pdparchitect.superbot-spki`

There is no broad home-folder, automation, camera, microphone, contacts, incoming-network, or personal-data entitlement. SuperBot explicitly points Codex at `~/.codex` but never copies or parses the credentials itself. The bundled Messenger helper is separately signed without the application entitlements.

The explicitly approved opt-in Agent Host is a second, distinct outside-App-Sandbox boundary. It has no extra entitlements, no root privileges, no login item, and no new global Mach-service exception. Absence of entitlements does **not** mean absence of access: the helper and its tools have ordinary user-process access, subject to macOS privacy controls and the harness/tool policies described above. `scripts/verify-agent-host.sh` verifies the assembled helper; the main app's reviewed six-entitlement policy remains unchanged.

Sparkle's framework runs inside the app sandbox. Its separately signed `Installer.xpc`, `Autoupdate`, and `Updater.app` form the explicitly approved outside-sandbox installation boundary needed to replace the app bundle. They have hardened runtime, the app's signing team, and no extra entitlement keys. `Downloader.xpc` is omitted because the app already has outgoing network access. `scripts/verify-updater.sh` checks the actual bundle's signatures, exact IPC names, signed-feed configuration, and absence of developer-machine framework search paths.

See [docs/architecture.md](docs/architecture.md) for the process and data flow.
