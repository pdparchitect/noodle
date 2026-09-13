# Changelog

All notable changes to Noodle are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Place the Heartbeat and Security bot-list scrollbars beside the rows so they no longer overlap the toggles.

- Give draft annotation and attachment chips a frosted glass background so conversation text scrolling behind them stays blurred and their labels remain readable.

- Use consistent status icons and text in Harness, Tools, and Companions settings, with green checks and labels for signed-in, ready, connected, and installed states.

- Use matching single-line chips for draft annotations and files. Show annotation comment excerpts, with the full comment and source filename available on hover and in the preview.

- Align draft annotations and attachment cards with the chat input, including while scrolling the attachment row.

- Keep attachment region annotations aligned with the preview and preserve its rounded corners. Replace the bottom banner with the same pointer-following hint used in conversations, hiding it when selection begins.

- Open noodlet attachments directly in Noodle Applet with full interaction, reusing an existing window instead of showing Quick Look’s file-information fallback. Keep the thumbnail in the conversation and update the agent skill to explain the behavior.

- Show image stacks as overlapping thumbnails with part of every picture exposed. Each picture opens its normal preview directly.

- Install the Applet skill automatically for every bot only while Noodle Applet is installed; remove its managed instructions and CLI links when the companion is removed, and restore them on reinstallation.

- Fix Runbar and build-and-launch commands failing after a successful build by keeping generated-help progress messages out of the returned application path.

- Make the capture comment divider span the preview width, removing the inset border at the image edge.

- Hide unavailable, transparent, and tiny helper-window previews from Capture. Prioritize the current display, then other desktop windows, then windows filling other displays or Spaces, with larger areas first and app/title tie-breaks. Validate previews with a short live stream, recover from temporary capture pauses, and remove sources that fail on selection until Refresh retries them. Use one Capture menu item that opens the Windows tab, with Screens available in the picker.

- Fix Apple replies repeating earlier answers or treating chat memory as a file task. Retrieve facts from original messages, preserve native tool sessions, and resume completed replies without repeating commands after interrupted delivery.

- Give Apple chat a bounded excerpt of recent user messages, limit history retrieval across each turn, and recover chat context overflow with one tool-free attempt from retrieved messages. Avoid suggesting that a short question caused the harness to fill its context.

### Added

- Add bug report and feature request forms, and require before and after screenshots when reviewing visual pull requests.

- Press Backspace (⌫) in a live or loading capture preview to return to the window or screen picker. Keep Backspace available for editing annotation comments.

- Annotate selected conversation text with ⌘⇧A or a region of the Noodle window with ⌘⇧R, adding comments and source context to the message draft. Both actions are available in the Conversation menu. Select regions inside the existing window with a hint that follows the pointer and disappears when selection begins.

- Attach live noodlets using `noodlet://UUID` bookmarks. Open their live creations on click, and let conversation participants use the shared creation through the Applet CLI.

- Choose Wrap, Vertical, or Stack for images in Settings → Chat. Wrap is the default and fits previews across each message before starting another row; Vertical keeps the original layout, and Stack overlaps the pictures while keeping each one directly previewable.
- Document noodlet window styles, sizing and frame restoration, native web requests without browser CORS, and Finder Quick Look for agents.

- Add Noodle Applet as a companion, with a managed noodlet creation skill and authenticated CLI access for bots to build, run, inspect, capture, and share their creations.

- Add a minimal black Noodle website with a product screenshot and a single download action, automatic GitHub Pages deployment for website changes on main, and custom domain setup instructions.

- Open Capture with ⌘⇧S, defaulting to Windows or focusing an existing preview without losing annotations. Show the shortcut in the existing attachment menu and allow customization in Settings → Keybindings.

- Add a Companions tab immediately before Update in Settings, showing installed companion app versions and offering an install link for missing apps, starting with Noodle Computer.

- Capture screens and app windows from the attachment menu with thumbnail selection and a live preview. Include windows across all displays and Spaces, including full-screen apps, with a compact, resizable preview utility available across Spaces and a single close control. Capture a plain PNG or freeze the displayed frame with the annotation shortcut, mark a region, and add a comment before adding it to the message draft.

- Add an experimental bundled Apple harness using the on-device Apple Intelligence model. Discover models through the helper, with one Default model initially; support reading and writing files, bounded shell commands, and Messenger replies through a separate restricted sandbox or the bot's explicitly enabled autonomous access.

### Changed

- Link Noodle Applet's download and documentation from the main README.
- Move Tools immediately after Security in Settings.
- Shorten the generated bot name options in General settings to “Real” and “Playful”.
- Display harness installation and update commands in a distinct inset box with larger monospaced text and an inline copy button.
- Describe the Applet skill explicitly as creative coding for utilities, games, interactive websites, prototypes, examples, and demos.
- Align Noodle Applet with Noodle Computer's native interface, settings, and menus; add Applet to the shared signed update and release pipeline.
- Put Codex first and Apple last in harness lists. Default new bots to the first available harness, using Apple when it is the only option, and warn that Apple is experimental and may be slow or unreliable.
- Show “Local” instead of the bundled executable path for the Apple harness in Settings, and shorten its availability status to “Ready”.
- Explain Apple’s experimental status in a wider, comfortably padded popover opened from its label, removing the repeated warning text from Harness settings.
- Keep each bot's identity and configuration in a copyable agent package, with separate working files and Noodle-managed runtime state. Automatically migrate existing workspaces before starting bots, preserving memory, skills, inbox positions, and session recovery state; interrupted migrations resume without overwriting files.
- Run restricted Codex processes in a dedicated filesystem sandbox that protects agent configuration and runtime state while allowing workspace files and Messenger replies. Store autonomous harness authorizations separately so changing or copying a bot's harness configuration cannot grant broader access.
- Preserve required migration releases in signed update feeds and require later releases to pass through them. Declare 0.13.0 as the first storage migration milestone and start update checks only after storage is ready.

## [0.12.1] - 2026-09-12

### Fixed

- Smooth the live recording waveform with continuous scrolling and gently appearing bars, respecting Reduce Motion.
- Recover automatically when microphone configuration changes interrupt audio startup or recording, and stop misreporting interrupted capture as a microphone settings problem.
- Prevent voice recording from getting stuck or crashing when the microphone format changes during startup. Use the current hardware format, convert captured buffers separately, report audio setup failures safely, and ignore cancelled startup work.
- Require the exact configured voice shortcut so extra modifiers cannot accidentally start or stop recording.
- Remove the fixed “1” badge from annotation region selections, leaving the orange outline and highlight.
- Keep the crosshair visible throughout annotation region selection despite delayed Quick Look cursor updates, and restore the normal cursor when commenting or cancelling.

## [0.12.0] - 2026-09-12

### Fixed

- Guide users with no installed harness from the empty chat area straight to Harness settings.
- Keep late automatic message-delivery decisions queued after their deadline, even when the timeout callback is delayed, and skip context loading for cancelled routing work.
- Size Keybindings settings to its contents, removing the empty space above Restore Defaults.
- Keep Space in the annotation comment editor instead of reopening the attachment and cancelling the popup, including image and 3D-model region annotations.
- Cancel active and queued MCP work on disconnect or caller cancellation, enforce request deadlines during queue waits and token refresh, and reject late sign-in callbacks.
- Make submitted annotation previews read-only. Remove Edit Comment and Save to Draft from sent notes, revoke editing in an open preview on submission, and reject later edits without creating a copy.
- Stop Grok and Muse inspection promptly when output closes, ignore unsolicited replies, and reject malformed responses instead of reporting misleading account or model status.
- Publish Computer CLI bridge messages only after their JSON is complete, preventing intermittent empty-response failures during file transfers and other commands.
- Let Quick Look finish its native close without requesting a second hide or bringing the preview forward from a delayed callback.
- Preserve consumed annotation keyboard events at the AppKit monitor boundary so Escape cancels the comment without also closing and flashing Quick Look. Save and Cancel return focus to the source attachment; holding Escape dismisses only the annotation, and a separate press can close the preview.
- Show bot runtime failures under the affected harness in Settings, with status details on sidebar avatars and a separate Kick action in failed bots' sidebar menus. Recognize Grok Build's exhausted usage allowance and pause automatic reconnect retries while preserving unfinished work.
- Keep ordinary attachments and annotations openable after closing a preview, switching conversations and returning, with one preview owner per chat window. Anchor annotation popovers at the pointer or the last selection point when invoked from the menu. Remove the redundant “Preview annotation” caption from annotation cards.
- Return sends and Escape discards voice recordings even when keyboard focus stays outside the recording bar after ⌘⇧D.
- Place sidebar unread dots in the left padding with a small gap before the avatar, keeping read and unread conversations aligned without excess indentation.
- Keep the chat cursor visible when typing beyond the input's six-line height limit, including after manual scrolling. Isolate height measurement from the live editor and limit it to six lines to reduce typing work for long drafts.

### Added

- Run message-delivery routing regressions in the default Swift suite with fake runtimes and classifiers, covering cancellation, deadlines, stale results, settings changes, and isolation between bots without harnesses or Apple Intelligence.
- Show an update notice in Noodle's computer picker when Noodle Computer needs updating for file transfers, with an action to open the app and automatic dismissal after compatibility checks detect the update.
- Add Settings → Keybindings immediately before Update, with a direct list of command descriptions and custom shortcuts for annotations, conversation search, bot/group creation, and voice recording. Changes update menus and hints immediately, persist across launches, and support clearing, per-command reset, and Restore Defaults with conflict checks.
- Cover MCP cancellation, disconnect, timeout, and sign-in races with controlled local HTTP fixtures and synthetic credentials; no accounts, browser sign-in, or Keychain access are required.
- Test Grok and Muse inspection with isolated local process fixtures in the default Swift suite, without installed harnesses, provider logins, or network requests.
- Transfer files directly between a bot's workspace and its assigned Computer with CLI `upload` and `download`, including binary files up to 8 GiB, assignment checks, and protection against overwriting existing files.
- Add broker regression tests for interrupted file transfers, revocation during a transfer, concurrent agents, invalid provider responses, and forged requests.
- Add regression tests for MCP HTTP redirects, response limits and cancellation, plus FX account/model inspection failures. Verify redirect blocking through URLSession and distinguish rejected icon responses from fallback artwork. Publish Noodle coverage summaries and downloadable reports in CI.
- Add regression tests for saved harness status, MCP icon validation, version probes, and attachment import failures.
- Edit unsent annotation comments from the preview. Draft notes update in place; submitted annotations are read-only.
- Annotate attachments in native Quick Look with ⌘⇧A for selected text or ⌘⇧R for a visual region. Save returns focus to the preview and adds a durable, clickable annotation attachment to the conversation draft. Text notes use plain text; visual notes use marked PNGs with comments and source metadata visible through the CLI. Composer and transcript attachments open a Quick Look-style annotation viewer with a compact translucent frame and a separate comment strip.

- Choose Automatic, Send immediately, or Queue message delivery in Chat settings. Automatic is the default and uses on-device Apple Intelligence to recognize urgent messages and changes to ongoing work, falling back to queueing when unavailable. Immediate delivery steers Codex and Muse, and interrupts Claude Code, FX, and Grok before checking the inbox.

- Start and stop voice recording in the active chat with ⌘⇧D, also shown in the Conversation menu and microphone tooltip. Stopping keeps the recording for review; Return sends and Escape discards.

- Add a code of conduct for the Noodle community.
- Add README badges for macOS, Swift, persistent agents, and individual or team work.
- Add a contributing guide for issues, development, and pull requests.
- Add a security notice covering agent access, privacy, and shared computers.
- Apache 2.0 license and copyright notice for Petko D. Petkov (pdp).

### Changed

- Cap the bot groups in Heartbeat and Security settings and scroll long lists within them, keeping controls and explanatory text visible. Resolve their height in the first layout pass to avoid a second resize when opening the tabs.
- Place Add Tools and Check Again in bottom footers with dividers in Tools and Harness settings, matching Keybindings.
- Move message delivery, microphone, @ menu descriptions, and link preview timeout into a new Chat settings tab. General now contains bot naming and the keep-awake option.
- Separate current group members from other agents in the composer’s @ menu.
- Document local web URL sharing from assigned computers.
- Organize the README documentation links as a list.
- Focus the READMEs and guides on getting work done with individual agents and teams; remove unnecessary detail and correct outdated instructions.

## [0.11.2] - 2026-09-11

### Changed

- Add a screenshot gallery to the Noodle README.

- Clarify the README opening and download descriptions, describe Noodle Computer as computers for your AI agents, replace em dashes with colons, and keep system requirements in Getting started.
- Share background import, presets, transitions and animated playback with Noodle Computer so both apps support the same media formats and behavior.

## [0.11.1] - 2026-09-11

### Fixed

- Computer web previews keep their loading message visible until the page finishes loading, then fade in smoothly to avoid startup flashing. Reduce Motion skips the fade.

### Changed

- Unread conversations show a blue dot centered beside the avatar, like Messages. The Dock icon shows the unread conversation count and clears when all conversations are read.
- Request notification badge permission and restore the Dock count after launch and authorization so existing unread conversations appear on the icon.

- Harness capabilities now determine bot access: Claude Code, FX, Grok Build and Muse Code always use autonomous access, overriding old restricted settings. Their Security switches stay on and disabled; creation explains the requirement, and startup errors appear inside the affected bot's row. Codex retains its configurable access setting.

- Upgrade release workflow actions to Node.js 24 versions, removing Node.js 20 deprecation warnings during preparation, publication and recovery.

- Require successful publication of every selected product before a release workflow can report success, including when GitHub skips a publication job.

- Scope release tests by product and run independent suites concurrently: Noodle-only releases skip Computer compilation, and image-only releases skip app compilation. Computer releases retain Noodle integration coverage.

- Fix image publication being skipped through an unchanged product’s job, and add recovery from verified release artifacts without rebuilding or moving tags.

- Release automation reads the three VERSION files on main, checks and prepares every selected product before minting derived tags, then publishes the verified app archives and images. Manual tagging is no longer required.

- README download links open the latest Noodle and Noodle Computer release pages, with installation instructions, so they stay current across releases.

- Add a prominent Download section for Noodle and Noodle Computer above the README feature list, with separate requirements and getting-started instructions.

## [0.11.0] - 2026-09-10

### Fixed

- Clicking empty padding near the chat input's rounded edges focuses the editor; text selection, microphone and send controls keep their normal behavior.

- Live voice recording shows fixed-width scrolling waveform bars on a consistent time scale, with clearer quiet-speech levels instead of progressively shrinking dashes. Saved audio keeps its full-recording overview.
- Voice recording keeps the normal composer height and glass style. General settings now offers a microphone selector; silent input is called out in the recording bar, and waveform metering handles integer PCM audio as well as floating-point samples.
- Group editor Members and Description headings use the same size and weight.
- Removed the explanatory media-format footer from the background editor; progress and errors remain visible when needed.
- Bot sidebar menus show Edit Bot, Change Background, then a separator before Show Workspace in Finder.
- Icon and background editors use matching button bezels, heights and equal widths for image selection and creation, without the chooser's extra left gap. Background swatches fill the preview width and idle progress no longer reserves empty space beside the buttons. Background Cancel and Apply use the same plain text style as other dialog headers.
- Muse no longer endlessly restarts a failed turn. Incompatible private model context gets one fresh-session recovery with old session IDs and chat history preserved; other terminal failures remain visible until Retry Startup. Model changes start new native context instead of replaying route-specific reasoning.
- Muse's existing saved login is now detected, including Keychain-backed accounts. Uncertain checks show an unknown status instead of misleading sign-in instructions; credentials never reach Settings.

### Added

- Noodle Computer integration with shared computer assignments across bots, generated CLI skills, and quiet provider discovery/startup without requiring the Computer window to be open.
- Interactive terminal and desktop attachment cards with Quick Look-style previews, remembered window geometry, and native-framebuffer thumbnails that avoid browser letterboxing and stretching.
- Computer setup and unavailable previews offer the public Computer download flow. Capability checks explain incompatible app versions; missing apps, removed computers and revoked assignments remain explicit recoverable states.

- Record voice messages from the composer on supported macOS 26 Macs, with a live waveform, on-device Apple transcription, Return to send and Escape to discard. Unsent recordings stay with their conversation; failed transcription offers retry or explicit audio-only sending. Chats show a compact audio player, with transcripts available from the context menu. Microphone access is requested only when recording is started.
- Voice-message attachments preserve audio with optional transcript, duration and waveform metadata, including transcript delivery to all harnesses without duplicating the spoken text in the message body.
- Muse Code harness with a theme-aware Meta mark, native-install detection, live MSP model catalogue and reasoning effort, terminal sign-in guidance, version checks, persistent sessions and interrupted-work recovery. Requires explicit per-bot autonomous access; the signed native binary is verified without executing its self-updating launcher.

## [0.10.1] - 2026-09-09

### Added

- Pipedream in the Tools catalogue, with its public MCP endpoint, bundled icon, editable description and account-aware instructions. OAuth discovery accepts a canonical root resource on the same HTTPS origin without changing the MCP endpoint or allowing cross-origin resource substitutions.

### Fixed

- Centered the General, Harness and Tools tabs in both New Bot and Edit Bot dialogs.
- Grok Build recognizes versioned binaries beside its native launcher, while preserving xAI signature verification. FX and Grok signature failures now include the underlying macOS error and failing check instead of an opaque warning.
- MCP credential storage uses Keychain's default calling-app access controls instead of deprecated access-list construction APIs. Existing Keychain items and sign-ins remain in place; token refresh preserves their access controls.
- Install and Relaunch proceeds through Sparkle without waiting for agent status, chat drafts, attachments, or open editors. Removed the silent restart postponement and quit veto; harness shutdown and recovery are unchanged.

## [0.10.0] - 2026-09-09

### Added

- The tool picker offers New Tool beside Done, a searchable catalogue of 35 browser-sign-in MCP services with bundled icons, and a Custom MCP form. Presets add in one step with editable default descriptions and instructions. New connections are selected in the current bot draft; saving that bot still controls assignment. The catalogue separates tool types from MCP-specific setup so other tool types can be added later.
- Built-in remote MCP connections with native OAuth sign-in, separate credentials for multiple accounts on the same server, and add/remove assignment in bot editors. Assigned bots receive generated skills and a bundled Swift CLI; Noodle holds the credentials and brokers tool calls independently of the selected harness. Server-provided icons are best-effort, with a native fallback.
- Messenger `--attach` accepts local paths, `file:///` URLs and public HTTP/HTTPS links. Links use the existing native attachment preview and Quick Look interaction, and are delivered to agents with a structured URL; local file previews remain unchanged.
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

- Generated MCP skills use readable names and simple skill-local commands without account UUIDs. Existing skills migrate automatically; Noodle still checks the bot's session and current connection assignment before dispatching calls.
- The Add Tools button sits inside a full-width rounded settings group, matching the other Settings action rows.
- MCP connections are labeled “Tools” in Settings and bot editors, with matching buttons, forms and help text. The protocol and saved connections are unchanged.
- The empty group-members area opens the Add Bots picker when clicked. Bot editor tabs and configuration headings use “Harness” consistently.
- Conversation reading positions survive app relaunches and restore by message identity, with a safe latest-message fallback if the saved message was removed. Initial transcript positioning targets real rows after loading instead of an estimated blank scroll extent.
- Bot and group editor Delete buttons use AppKit's subdued red destructive appearance rather than a bright-red fill or neutral SwiftUI button. Labels omit ellipses; confirmation dialogs are unchanged.
- Returning from MCP browser sign-in reuses the existing chat window and restores focus to the Settings window that started the connection, rather than opening a second chat window.
- Bot editors use General, Harness and Tools tabs with content-fitted, animated sheet resizing. Draft settings survive tab changes.
- MCP settings and connection forms are more compact, with a rounded instructions editor. MCP sign-in opens in the normal default browser with access to existing profiles and extensions; validated app callbacks, PKCE and sign-in timeouts remain enforced.
- Updated Grok Build installations are recognized when the official launcher points to a versioned download. The native installation location and xAI code-signature checks remain enforced.
- Resizing the conversation window anchors the message being read as text reflows, instead of retaining a pixel offset that can jump to different content. Chats already at the bottom continue following the latest message.
- Shift+Tab from the chat input returns focus directly to the selected sidebar conversation, preserving the draft and allowing Up/Down navigation to resume.
- Switching conversations keeps keyboard focus in the sidebar for Up/Down navigation. Tab from the conversation list jumps directly to the chat input, without changing search, menu or modified-key navigation.
- Empty and one-line chat drafts have identical composer heights, preventing the conversation from jumping when typing the first character or clearing the input. Additional lines still expand the composer normally.
- The main conversation shows its native vertical scrollbar according to macOS scroll-bar preferences, with clearance above the overlaid composer. Message layout, saved scroll positions and follow-latest behaviour are unchanged.
- Long chat drafts now have native trackpad scrolling and an automatically hiding scrollbar within the existing six-line composer. Pasting stays plain text; Enter sends, Shift+Enter adds a line, and native undo and bot-name completion are preserved.
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

[Unreleased]: https://github.com/pdparchitect/noodle/compare/v0.12.1...HEAD
[0.12.1]: https://github.com/pdparchitect/noodle/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/pdparchitect/noodle/compare/v0.11.2...v0.12.0
[0.9.0]: https://github.com/pdparchitect/noodle/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/pdparchitect/noodle/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/pdparchitect/noodle/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/pdparchitect/noodle/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/pdparchitect/noodle/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/pdparchitect/noodle/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/pdparchitect/noodle/releases/tag/v0.3.0
