# Using Noodle

## Features

- Create and edit UUID-backed bots
- Give each bot an editable backstory stored canonically in `AGENTS.md`
- Explicitly assign one of the installed, supported harnesses to each bot
- Read live Codex, FX and Grok Build model catalogues and offer Claude Code's standard Fable, Opus, Sonnet, and Haiku aliases with effort levels
- Maintain one persistent Codex App Server thread, Claude Code stream-json session, or FX/Grok Build ACP session per bot
- Start every configured bot with Noodle and stop every bot when Noodle terminates
- Notify bots without copying message bodies into the harness event
- Let harnesses read and reply through the bundled Messenger CLI (FX remains experimental pending upstream review-service recovery)
- Persist direct chats, group chats, unread inbox cursors, and linked attachments
- Render common inline Markdown in selectable message text, with safe web and email links
- Show durable unread indicators for conversations with unseen bot replies
- Accept any regular file attachment, show selectable inline thumbnails outside the message bubble, and open Quick Look-compatible files—including PDFs—with Space or a double-click
- Install and update the managed Messenger skill without touching a bot's other skills
- Bundle a separately signed, minimal `messenger` command for every harness
- Expose a native “Send Noodle Command” App Intent to Spotlight and Shortcuts
- Observe Messenger replies in the open conversation without relaunching the app
- Show native macOS notifications with the sending bot's avatar while Noodle is unfocused, hidden, minimized, or has no open window
- Check for signed updates hosted entirely on GitHub and install/relaunch without interrupting active agents
- Wake idle agents with configurable inactivity heartbeats, enabled by default after 30 minutes
- Generate either conventional real names or playful names when creating bots

## Link previews

Visible links load previews on demand. **Settings → General → Link preview timeout** sets the maximum time for a new preview, including its thumbnail: 5, 10 (default), 20, or 30 seconds. If the site has no image, fails, or takes too long, the spinner stops and the card remains clickable with a link icon and any available title. Results, including failed attempts, are kept in a bounded in-memory cache so ordinary row redraws do not continually retry. The setting applies to new requests; existing requests retain their deadline.

## Groups

Groups can contain **one or more bots**. Their editable names are separate from the stable UUIDs that own their histories, attachments, backgrounds, and agent references. New Group and Group Info share an **Add Bots** search picker and a grid of selected avatars with individual remove controls. Saving an empty group is not allowed; removing a member does not delete the bot or conversation history.

## Quick send with Spotlight and Shortcuts

Install and launch the signed app once, then press Command-Space and search for **Send Noodle Command**. Choose any current bot or group, enter the command, and macOS delivers it without bringing Noodle to the foreground. The same action is available in the Shortcuts app for custom keyboard shortcuts, menu-bar shortcuts, and automations.

Bot and group suggestions update after creation, rename, membership changes, and deletion. An App Intent command follows the same path as the composer: Noodle persists a normal user message and notifies every participating bot.

Noodle asks for notification permission on first launch. Notifications use the bot name as the title, include the group name when relevant, and open the corresponding conversation when clicked. They are suppressed while a visible Noodle window is active.

## Runtime recovery

Configured bots are restarted automatically when their harness exits, the autonomous XPC connection breaks, or a dead runtime is found by Noodle's health check. Retries begin quickly and back off to at most once every 30 seconds while the underlying installation or account remains unavailable. Waking the Mac runs the same reconciliation immediately. Intentional stops during bot deletion, access-mode changes, updates, or application termination do not trigger a restart.

Each replacement resumes the bot's persisted Codex thread or Claude Code session. When the failure interrupted active work or a pending inbox notification, Noodle sends a private `runtime-recovered` event that tells the bot to check its inbox and continue safely while avoiding duplicate consequential actions. Ready bots restart silently.

## Agent heartbeats

**Settings → Heartbeat** enables or disables inactivity wake-ups globally or for individual bots and sets the idle interval (30 minutes by default, configurable from 1 minute to 24 hours). Each bot has its own persisted timer. Incoming notifications, outgoing messages and reactions, active harness work, and completion of a turn restart that timer. Launching Noodle, starting a runtime, merely viewing a conversation, and polling for messages do not reset it.

After a full quiet interval, Noodle delivers a distinct `<noodle-event type="heartbeat" />` to a ready, idle agent using the same harness turn mechanism as message notifications. It never interrupts an active turn, queues stale heartbeats behind messages, or starts offline/failed bots. Normal incoming messages still take priority. If the interval expires while Noodle is closed, one overdue heartbeat runs after that bot becomes ready on the next launch. A heartbeat that finishes without a reply starts another full idle interval; waking the Mac after a long sleep likewise produces at most one overdue heartbeat per idle bot, not a backlog of turns.

The agent checks Messenger, then reviews its existing Backstory, memory, and previously assigned work for useful authorized follow-ups. Heartbeats do not grant new authority. Agents are instructed not to invent work or send routine heartbeat acknowledgements. Each heartbeat may consume model tokens even when it produces no chat message.

Preferences persist across launches. Timers start fresh when agents reconnect, when the global interval/switch changes, or when a bot's individual switch changes. Heartbeats run only while Noodle is running; they do not launch the app or wake a sleeping Mac. No additional sandbox entitlement is needed.

## Settings

Settings are ordered **General → Harnesses → Heartbeat → Security → Updates → Dev**. General controls whether generated bot names use conventional real names or the playful adjective–noun style. It also offers **Keep Mac awake while agents work**, an opt-in setting that prevents automatic idle sleep while any bot is working and releases that assertion as soon as all bots are idle. macOS still sleeps when the lid is closed or the user explicitly chooses Sleep. The entire Dev tab is compiled out of release builds.

For bot permissions and startup errors, see [Security and agent access](security.md). For update preferences, see [In-app updates](releases.md#in-app-updates). For a development build with the Dev tab, see [Development](development.md).


---

[Documentation](README.md) · [Noodle](../README.md)
