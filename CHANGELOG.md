# Changelog

All notable changes to Noodle are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Messenger `--attach` accepts local paths, `file:///` URLs and public HTTP/HTTPS links. Links appear as separate preview cards with a clickable fallback and are delivered to agents with a structured URL; local file previews remain unchanged.
- The background file picker accepts muted, looping MP4/M4V/MOV videos and HEIC wallpapers. Multi-image HEIC files cycle through their frames with gentle fades; single-image HEIC stays still. Playback pauses when the window is hidden or Reduce Motion is enabled, and imported files are retained inside Noodle.
- The isolated Chat Feature Tests window includes an editable Markdown source and live chat-renderer preview, alongside its existing chat controls.
- Harness Settings shows installed versions for Codex, Claude Code, FX and Grok Build, checks for newer public releases, and flags missing command support separately as **Update required**. Provider-specific update instructions are available without automatic installation; version checks are bounded, cached and read-only.
- The composer’s + button opens a native menu with **Attach File…** and **Choose Photo…** from the system Photos picker. Selected photos stay in the originating chat’s draft; normal paste remains unchanged, without a separate paste menu item.
- Attached-image background changes ask for confirmation. Direct-chat images also offer **Use as Icon**, with confirmation before changing the bot's icon throughout Noodle.
- Right-click an attached image from anyone in a DM or group to use it as that conversation's background. The original attachment stays unchanged.
- Bot avatars in direct messages (including the chat header) open an informational profile with name, enlarged avatar and public description. Hover tooltips match group avatars; DM profiles omit the group reply and direct-message actions.
- Grok Build harness with a theme-aware vector icon, existing-login detection, live model and reasoning-effort discovery, persistent ACP sessions, Messenger replies and interrupted-work recovery. Requires explicit per-bot autonomous access; installation and terminal sign-in guidance are included.
- General settings now offers a link-preview timeout (5–30 seconds, default 10), covering both metadata and thumbnail loading.
- Experimental Vercel FX harness with a native template icon, official installation guidance, existing-account detection, Vercel sign-in, live model discovery, persistent ACP sessions, Messenger wake events and interrupted-work recovery. FX requires explicit autonomous access. Its safety-review failure currently blocks live Messenger round-trip verification; held tool execution is reported as a failure, not readiness.

### Fixed

- Harness update instructions only appear when a newer version is confirmed. Failed version checks no longer add an inline error label to Settings.
- Bot and group names use single-line fields with validation against multiline or oversized pasted text. Existing malformed names can no longer expand the chat header or empty-message placeholder; descriptions, backstories and messages remain multiline.
- Shift+Enter inserts a new line in the chat input; Enter continues to send. Native text editing, undo and bot-name menu navigation are preserved.
- Harness Settings remembers confirmed installation and sign-in status across launches and keeps it visible during Check Again. Incomplete discovery no longer flashes “Not installed”; cached status is display-only and never authorizes harness execution.
- The attachment menu offers **Use as Background** only for recognized images, not documents with Quick Look thumbnails; the menu label is shorter.
- Switching chats preserves each conversation's unsent text and queued attachments for the current app session. Sending clears only that conversation's draft, and automatic update restarts wait for drafts in all chats.
- Recognized FX transport failures now explain interrupted model connections and how to resume, without echoing private provider errors or incorrectly implying a lost login.
- Link previews stop loading when a site has no image, an image fails, or the total deadline expires. Failed previews stay clickable, cache their fallback, cancel outstanding work, and ignore late callbacks.
- Model search disables autocorrection while preserving the original plain SwiftUI field and rounded search-bar appearance.
- The Agent Host joins the app's login security session so FX can access its existing Keychain login instead of incorrectly asking signed-in users to authenticate again.
- The Help menu's **Noodle Help** item opens the project's GitHub page in the default browser.
- Codex and Claude bots persist unfinished turns before dispatch and receive a recovery wake after Noodle restarts, including force-quits. Completed and idle bots are not woken just because the app reopened.

### Changed

- Removed the Dev Settings tab; runtime diagnostics remain in internal test tools.
- Settings tabs use the singular labels **Harness** and **Update**.
- New bots default to restricted access; existing bots retain their access settings. Autonomous access remains an explicit per-bot option in Security, required by the current Claude Code harness.

## [0.9.0] - 2026-09-08

### Added

- The `@` menu shows dimmed public bot descriptions by default, with ellipses for long descriptions and a General setting to turn them off.
- Click a bot's avatar in a group message to see its public profile, address it by name in the composer, or open its direct conversation.
- Type `@` in the chat composer to open a native macOS bot-name menu with system styling, keyboard navigation and type-to-select. Choose a name with Return or a click to insert plain text.
- Privacy-safe runtime lifecycle and inbox-read logs in debug and release builds, with wake correlation IDs and extra debug-only notification diagnostics.
- A shared message/event catalogue generates agent guidance, Messenger help, and the message reference, with build and test checks for documentation drift.
- First-class Claude Code harness support with crisp vector Claude Code and Codex marks, native-install discovery, isolated account setup, standard Fable, Opus, Sonnet, and Haiku choices, effort controls, persistent stream-json sessions, supervised recovery, and Messenger-based conversations.
- An opt-in General setting that prevents automatic Mac sleep only while at least one agent is working.
- Supervised agent runtimes that restart after unexpected Codex exits or Mac wake, use bounded retry backoff, and safely resume interrupted work.
- Native link previews for safe public web links, with compact cards, lazy loading, and inline image previews.
- Public bot descriptions, group membership notices, and a Messenger roster command that reports each participant's name, description, and conversation-local activity without exposing private backstories.
- Public group descriptions that are editable, searchable, visible in the conversation, and supplied to every member as shared context. Description changes notify the group.

### Changed

- Bot startup instructions now point to the Messenger skill instead of repeating its full guidance, reducing redundant agent context while preserving backstories.
- Autonomous harness launch now validates either OpenAI's signed Codex package or Anthropic's signed Claude Code native install and maps provider settings to fixed commands without exposing an arbitrary execution endpoint.
- Long conversations keep transcript loading off the main thread, reuse parsed Markdown, virtualize off-screen messages, defer attachment thumbnails until visible, batch scroll-position updates, and use indexed attachment lookups to reduce typing and scrolling stalls.
- Sidebar message previews now show clean plain text without displaying Markdown syntax.
- Link and attachment previews use compact, top-leading layouts and repair incorrectly labelled image attachments when possible.

### Fixed

- Release packaging validates the same seven-key sandbox policy as the smoke tests, including Claude Code's exact read-only executable paths.
- Transcript geometry updates no longer feed back into scroll-to-bottom commands; short conversations are correctly treated as fully visible with titlebar insets.
- The name menu uses the same avatars as the sidebar, including generated colours and symbols as well as uploaded portraits.
- Bot profiles dismiss when clicking outside or switching away from the app; the native name menu uses circular avatars and a comfortable minimum width.
- Bot workspace bootstrap exposes shared skills through Claude Code's native `.claude/skills` discovery path, preserving existing Claude settings and native skills.
- Editor sheets resize in both directions as their content changes, avoiding gaps and clipped headers; large group membership grids scroll within a bounded height.
- Claude bots recover from explicitly missing saved sessions instead of endlessly restarting; new session IDs are saved only after Claude confirms startup, and unrelated failures preserve existing session pointers.
- Inbox-read diagnostics are relayed by Noodle when sandboxed Messenger commands cannot reach macOS logging, including successful empty checks and read failures.
- The application-menu update command remains responsive after Sparkle enables update checks.
- Harness icons use transparent vector templates that inherit native foreground styling alongside system symbols; Codex path rendering no longer clips on macOS.

## [0.8.0] - 2026-09-07

### Added

- Persistent last-heartbeat information for every bot.
- Stable, human-readable names for the Codex sessions created by Noodle agents.
- A real product screenshot and a download-focused project README.

### Changed

- Local development builds now use isolated data by default, with an explicit production-data build mode when shared state is required.
- Agent access is autonomous by default, while per-bot restrictions remain available.
- Groups can be renamed without changing their identifiers, membership, or history.
- Messages render inline Markdown, and the chat composer uses a Liquid Glass treatment.
- Conversations scroll beneath the composer and fade beneath the window toolbar.
- The redundant workspace button was removed from conversation headers; workspace access remains in the sidebar context menu.

### Fixed

- Heartbeat idleness survives app relaunches instead of restarting whenever Noodle opens.
- Chat bubble styling, unread indicators, transcript fades, and bottom-edge scrolling remain legible across conversation backgrounds.

## [0.7.0] - 2026-09-07

### Added

- Guided Codex installation and sign-in setup with clearer runtime and model selection.
- Configurable bot-name styles, defaulting to conventional real names.
- File and Image Playground artwork for bot icons, plus generated conversation backgrounds.
- Continuous spelling assistance in the chat composer and bot editor.
- Improved single-member group presentation and heartbeat interval controls.

### Changed

- Settings and modal sheets fit their content and keep dynamically changing controls stable.
- Bot creation and editing use simpler, provider-neutral language and controls.

### Fixed

- Extended agents resolve the correct application container and validate the official Codex installation correctly.
- Bot icon generation avoids unwanted personalization and no longer requires seed text.

## [0.6.0] - 2026-09-06

### Added

- Configurable, independent inactivity heartbeats for persistent agents.
- Optional extended agent access through a separately signed host, with per-bot security controls.
- Single-bot groups and a searchable avatar-based membership picker.
- Durable Messenger chat effects, including foreground confetti with replay and reduced-motion support.
- Recovery for unread notifications and inbox cursors stored outside managed skill files.

### Changed

- SuperBot was renamed to Noodle across the app, modules, bundle identifiers, documentation, release pipeline, and artwork.
- Settings were reorganized and runtime diagnostics moved into a debug-only developer tab.

### Security

- Extended access requires the trusted Codex installation and is isolated in a hardened helper rather than widening the main app sandbox.
- Confirmation-only tool requests gained explicit consent handling.

## [0.5.0] - 2026-09-05

### Added

- Signed in-app updates through Sparkle, including automatic checks and optional automatic installation.
- Signed update feeds and checksums published with every GitHub release.

### Changed

- Update relaunches wait until active agents, drafts, attachments, editors, and shared-item deliveries are safe to interrupt.

### Security

- The updater bootstrap validates signed archives and integrates with the notarized release pipeline.

## [0.4.0] - 2026-09-05

### Added

- Native attachment paste, browser drag-and-drop, and context-menu copying.
- Message reactions for users and agents, including named reaction history through Messenger.
- A native Settings window showing detected agent harnesses.
- A sandboxed macOS Share extension and Services-based sharing composer.
- Private per-conversation backgrounds for both bots and groups, including Photos Library import.
- Group editing from sidebar context menus.

### Fixed

- Agent startup I/O and large history decoding no longer block the interface.
- Conversation scroll positions restore without delayed jumps or cumulative drift.
- Transcript fades and background transitions remain correctly layered around the toolbar and messages.

## [0.3.0] - 2026-09-05

### Added

- The first native macOS release, originally named SuperBot, with persistent direct and group conversations.
- Long-running Codex agents with stable private workspaces, editable backstories, model settings, and durable conversation history.
- The agent-local Messenger command for named message delivery, group communication, and file attachments.
- Native bot icons and avatars, inline attachment thumbnails, Quick Look previews, and drag-and-drop attachments.
- Background reply notifications, unread conversation indicators, and Spotlight/Shortcuts quick-send actions.
- Group membership editing and confirmed deletion for bots and groups.

### Security

- Signed and notarized macOS packaging with a dedicated Developer ID identity.
- Sandboxed messaging and explicit attachment paths for agent file access.

[Unreleased]: https://github.com/pdparchitect/noodle/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/pdparchitect/noodle/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/pdparchitect/noodle/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/pdparchitect/noodle/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/pdparchitect/noodle/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/pdparchitect/noodle/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/pdparchitect/noodle/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/pdparchitect/noodle/releases/tag/v0.3.0
