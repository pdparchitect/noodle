# Changelog

All notable changes to Noodle are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Pin bots and groups to the top of the sidebar. Choose Pin from a conversation's context menu to move it under a Pinned header, which appears only while something is pinned. Pins stay across restarts.

### Fixed

- Let a Codex profile sign in again after its saved login stops working. Sign In… used to stop at "Could not check sign-in status" when Codex could no longer read the old login, for example after its refresh token was used up. It now starts a new sign-in, and a failed status check includes the reason Codex gave.
- Put the scroll bar at the edge of the calendar and reminder list chooser. It used to sit right after the longest list name.
- Open the right conversation at the right message when a notification is clicked. A click used to do nothing if the main window was closed or the click launched Noodle, and it never scrolled to the new message. It now opens the conversation where it is shown, or in the main window, and scrolls to the message.
- Send attached files with a voice message. Files added before recording used to stay behind in the message box; they now go out with the recording. Typed text still stays in the box.
- Centre the website’s top links on the page. They used to sit between the logo and the Download button, off to one side.

## [0.25.0] - 2026-09-24

### Fixed

- Take the Reminders grant the first time it is given. macOS hands back the access and then keeps reporting
  that it was never asked, which left the Reminders tool row on "Allow access to choose reminder lists"
  however often the button was pressed, and kept the bot's lists out of reach. The grant now stands, and a
  request that genuinely fails says why instead of falling silent.
- Stop a stuck microphone from freezing Noodle. After a USB microphone reconnects, macOS can leave its audio input
  hanging indefinitely; Noodle used to wait on it and spin. Recording now gives up after a few seconds with
  "The microphone isn’t responding" and the rest of the app keeps working.
- Remove a coordinate system from the conversation transition, a further cause of message text that appears upside down until the conversation is switched away from and back.
- Keep a noodlet quiet while it is out of sight. A noodlet a bot runs in the background or headless no longer plays sound on the Mac: HTML pages are muted until they are shown and muted again when they are hidden, and a Swift noodlet started outside the foreground runs without audio output. A noodlet granted the microphone keeps its audio.
- Open a noodlet in the foreground when it is clicked, whatever the bot left running. A background page is shown and unmuted; a Swift noodlet or a headless test session, which cannot gain sound or normal data after it launched, is closed and started again in the foreground.

### Added

- Add `messenger tool vision cutout`, which removes the background from an image in the bot's workspace and writes the subject on transparency as a PNG. It can keep every subject or just one, and trim the result to what it kept. Like the other vision tools it runs on this Mac and sends nothing anywhere.

## [0.24.0] - 2026-09-22

### Changed

- Offer OpenAI, Anthropic, Meta and xAI as tiles in Set Up Your First Bot, with their harness and its state on this Mac. The other harnesses are listed under Other, which opens by itself when one of them is the best choice.

### Added

- Give bots the calendars and reminder lists on this Mac. The bot editor's Tools tab assigns them beside tool connections: a bot can read what it was given, and create, change and delete events and reminders in those calendars and lists only. Noodle asks macOS for access the first time, separately for calendars and for reminders.
- Add Perplexity to the tool catalogue in Settings > Tools > Add Tools. Sign-in uses Perplexity's browser OAuth, and bots get web search with sources.

### Fixed

- Open the sidebar at its intended width. It came up at the narrowest width the system allows, with bot names cut short, until it was dragged wider.
- Keep Sign In usable in Settings > Harness while other harnesses or version lookups are still being checked. It waits only for that harness's own sign-in check.
- Pause a Claude Code bot for sign-in when its login has expired, instead of reporting it ready and retrying every heartbeat. The harness shows Needs attention, and Kick resumes the unfinished turn after signing in.
- Keep a message still when a reaction lands on it. The transcript now always leaves room for the badges, so a message no longer jumps down as one appears or disappears.

## [0.23.1] - 2026-09-21

### Added

- Show which conversations have unread messages in the conversation picker: a blue dot before the name, the same dot as the sidebar.

### Fixed

- Stop asking for the login keychain password when a restricted FX bot starts. FX recreates its login item when it refreshes, which dropped Always Allow each time.
- Keep typing in the message field responsive in long conversations. Each keystroke used to redraw every visible message.
- Stop searching every visible message for a link again whenever the conversation redraws, such as when a message arrives or while scrolling.
- Open long conversations faster. Noodle used to build every message of the conversation when it opened, not only the ones on screen.

## [0.23.0] - 2026-09-21

### Added

- Give each Noodle Computer an optional description of what it is for. Assigned bots receive it with the computer's name from `computer list` so they choose the right computer; the bot editor's computer picker shows and searches it. Preview cards never include it.
- Add Google Antigravity as a harness. Noodle finds `agy` at `~/.local/bin/agy` or installs it from Google, checking the published SHA-512 and Google's signature, lists its models, and runs restricted and unrestricted bots that resume their conversation. Sign in by running `agy` in Terminal. Antigravity supports profiles, each a separate home with its own sign-in. An urgent message waits for the current turn to end, because Antigravity cannot be interrupted.
- Show whether a bot is working in separate and floating conversation windows: the picture in the window title now carries the same status dot as the sidebar (blue working, green ready, red failed, grey otherwise). Hover it for details.
- Turn Open into Update in Settings > Companions when a companion is behind its feed. It opens the companion and starts its update check, so the update is offered without a second step. Companions released before this still get Open.
- Add a Show in Main Window button to the title bar of separate and floating conversation windows. It closes the window, ends floating, and selects the conversation in the main window, reopening the main window if it was closed.
- Give every bot a built-in `tips` skill with advice for situations it cannot resolve alone. The first tip: when the sandbox blocks a command, file operation, install or network request, the bot stops retrying, works in an assigned computer if it has one, and otherwise asks you to assign it one in Edit Bot → Computers. A second tip covers a tool connection that needs sign-in. Every bot's generated `AGENTS.md` now has a short Sandbox section, so all harnesses learn what a restricted bot can write, not only Codex. Codex bots no longer get extra access guidance that other harnesses lacked, and tool connection skills point at the tips instead of giving their own advice. A custom skill named `tips` is kept.

### Changed

- Show the actions of each row in Settings > Harness (Profiles, Update, Remove, Local Models, Sign In), Settings > Tools (Connect, Edit, Remove) and Settings > Companions (Open, Install) as links instead of buttons, without the trailing ellipsis, so the lists take less room.

### Fixed

- Stop macOS asking for the login keychain password every time a restricted Claude Code bot starts, even after Always Allow. Noodle Agent Host now reads the `Claude Code-credentials` item the way Claude Code does, which needs no prompt.

## [0.22.0] - 2026-09-21

### Added

- Let bots mark a major milestone with fireworks: `messenger --effect fireworks` plays rockets that burst over the chat. Like confetti, it plays once in the foreground chat and shows a still 🎆 under Reduce Motion.
- Keep a conversation above other apps: Float on Top, in the sidebar menu or a conversation window's menu, holds it over every Space and full-screen app at a smaller minimum size, blurs what is behind it in place of the background, keeps only the close button, and floats again after relaunch. Open in New Window returns it to a normal window. Press ⌃⌥Space in any app (change it in Settings > Keybindings), or choose Conversation > Choose Conversation…, to pick a bot or group from a grid and land it as a floating window by the pointer. Open floats are listed first with a badge, and new ones step aside so they do not hide each other. The Conversation menu also has Open in New Window and Float on Top for the current chat.
- Add Settings > Chat > Keep one floating conversation, off by default. When on, floating another conversation closes the open float and takes its exact place and size.
- Show the bot's or group's picture beside the name in the title of separate and floating conversation windows.
- Put the caret in the message field whenever a conversation window opens or is brought back, floating or not.
- Press Return (↩) in a live capture preview to add the frame to your message, so a capture runs from the keyboard: arrows, Return to open a source, Return again to capture.

### Changed

- Make the status under your messages mean something: a message shows Sent until a bot's harness fetches it, then Delivered. In a group it is delivered once any member fetches it. Messages shared from other apps, which stayed on Waiting for harness, follow the same rule.
- Ask for confirmation before turning on Unrestricted access or Apps for a bot in Settings > Sandbox. Turning either off still applies at once.
- Show a reset button beside each changed shortcut in Settings > Keybindings, so one command can return to its default without restoring them all.
- Accept Option (⌥) alone as the modifier for any shortcut in Settings > Keybindings, such as ⌥Space. Shift alone or no modifier is still rejected.
- Rename the Settings > Update button to Install Update… once a newer version is found. The app menu keeps Check for Updates….
- Leave development test fixtures out of the released app, which makes it smaller. They remain in Noodle Dev.

## [0.21.0] - 2026-09-20

### Added

- Give every bot on-device image tools: `messenger tool vision ocr`, `classify` and `barcodes` read text, labels, barcodes and QR codes from an image in the bot's workspace, so models that cannot see images can still use them. The tools run in a sandboxed extension with no network or file access; Noodle opens the image for it.
- Let one script use every tool Noodle provides: `messenger tool --run FILE` and `--eval CODE` work without naming a provider, and `tools.call(provider, name, input)` chains results between them, such as reading a browser screenshot with Vision and writing the text to a tool connection. Noodle checks each call exactly as it checks a single command.
- Provide tool connections through `messenger tool`, one provider per connection, with its resources as the tools `mcp-resources` and `mcp-read-resource`, scripts as `--run FILE` and `--eval CODE`, and JSON arguments on standard input with `--input -`. A connection is assigned to a bot as a whole and Noodle checks that before and after every call. Nothing a remote server sends can make Noodle open workspace files for it or post into a conversation.
- Save images, audio and other binary results from any tool as files under `.noodle/tool-attachments` in the bot's workspace, not only results from tool connections.
- Provide assigned computers through `messenger tool computer`, from a bundled Computer tool extension that talks to Noodle Computer directly. Noodle still decides which computers a bot may use: it checks the computer named in every call, filters the list, answers the extension again immediately before a command or staged upload is sent, withholds a result if the computer was unassigned meanwhile and then closes the bot's terminals there, and posts a preview card only into a conversation the bot belongs to. Requires the next Noodle Computer release, which accepts the extension's connection.
- Provide assigned browsers through `messenger tool browser`, from a bundled Browser tool extension that talks to Noodle Browser directly. Noodle still decides which browsers a bot may use: it checks the browser named in every call, filters the browser list, withholds a result if the browser was unassigned while the call ran, and posts a page card only into a conversation the bot belongs to. Requires the next Noodle Browser release, which accepts the extension's connection.
- Teach bots `messenger tool`, one command that lists the tools Noodle provides to a bot and calls them, with options typed from each tool's schema. Tool extensions bundled with Noodle are discovered automatically, and each one appears in the bot's workspace as a skill generated from its own description.
- Set Up Your First Bot opens the first time Noodle starts with no bots. It lists each harness with its state on this Mac, installs the one you choose if it is missing, signs you in, and creates the bot once you name it. Not Now closes it, the empty main window keeps a Set Up Your First Bot button, and Help > Set Up a Bot… opens it at any time.
- Teach bots that native noodlets run confined to their own files and reach user-selected files through `NoodletContext.files`.
- Teach bots to keep noodlet API keys in the new per-noodlet secrets store instead of source or data files.
- Teach bots the Applet skill's new `noodlet typecheck` command, which checks any Swift file or folder without building a noodlet, and the `permissions` manifest key for microphone, camera, speech recognition and screen recording.
- Install Codex, Claude Code, FX, Grok Build, Muse Code and OpenCode from Settings > Harness without Terminal. Install downloads the provider's current release into Noodle's storage, where it is checked against the provider's Apple code signature before it can run, and the row then reads Installed by Noodle with Update and Remove… beside it. A harness you installed yourself always takes priority: Noodle never installs over it, and deletes its own copy at the next launch once yours appears. Noodle keeps its own copies up to date, which Update harnesses installed by Noodle automatically turns off, and returns to the previous version if a new release does not work with Noodle. Install Manually… keeps the Terminal command.
- Sign Codex, Grok Build and Muse Code in to more than one account. Profiles… under the harness in Settings > Harness opens the list, each profile with its own sign-in kept in Noodle's storage, and Edit Bot > Harness chooses which one a bot uses. System remains the default and is the harness login already on this Mac. Grok Build and Muse Code profiles sign in with a device code shown in Noodle, without Terminal. An unrestricted bot on a profile uses that profile's harness configuration instead of the one in your home folder. Deleting a profile returns its bots to System.
- Share folders outside the workspace with a bot in Edit Bot > Harness, each as Read & Write or Read Only and with an optional description of what it is for. A restricted bot's sandbox opens only those folders in addition to its workspace, and they are listed with their descriptions in the bot's generated `AGENTS.md`. Saving restarts the bot. Noodle's own storage and the whole disk cannot be shared.
- Import and run Gemma 4 local models, and offer Gemma 4 E4B in Local Models. Noodle loads the text model only; the checkpoint's image and audio weights are copied but unused.
- Offer Qwen3 1.7B and Qwen3 14B in Local Models alongside Qwen3 4B Instruct and Qwen3 8B. The list is now titled Available and runs from smallest to largest, each model has a one-line description of what it suits and the memory it wants, and the best fit for this Mac's memory is tagged Recommended.

### Changed

- Require macOS 26 or later, as Noodle Browser and Noodle Computer already do. Tool extensions are discovered with system APIs introduced there.
- List the tools Noodle provides under one Tools heading in each bot's instructions, generated from the skills its tool extensions supply, instead of separate fixed notes for browsers and computers.
- Remove the `mcpshim` command and the per-connection skills written around it. Bots use `messenger tool CONNECTION` with the same JavaScript API; Noodle removes the old skills, their `mcpshim` links and the request folder from each bot's workspace, and keeps any files a bot added there. Binary results now go to `.noodle/tool-attachments`; files already in `.noodle/mcp-attachments` stay where they are.
- Remove the separate `browser` and `computer` commands and their hand-written skills. Bots use `messenger tool browser` and `messenger tool computer` with the same tool and option names, including `present`; Noodle removes the old skills and their request folders from each bot's workspace. `computer present` now always names the computer with `--computer`, also when it names a terminal, so the assignment is checked before anything runs.
- Register 0.21.0 as an update milestone. Installations older than 0.21.0 receive it before any later release, so it can remove the skills, command links and request folders earlier versions wrote into bot workspaces.
- Retire the 0.13.0 storage migration and the 0.14.0 Backstory import. Updates already pass through both releases; a bot package older than either is left unchanged and startup names the release to run first.
- Sign Grok Build and Muse Code in to their system account from Settings > Harness with a device code shown in Noodle, as their profiles already did. Terminal is no longer needed.
- Ask for confirmation before removing a tool connection, computer, browser or shared folder from a bot in the bot editor. The removal still applies only when the bot is saved, and the tool, companion or folder itself is kept.
- Remove the explanatory footer beneath the companion list in Settings > Companions.
- Show installed models in Local Models the same way as the Available list, with their description, size and details link, and drop a model from Available once it is installed.
- Remove Messenger's `--get-latest --inline-images` option, which returned images to bots as base64 data. Every harness now reads the inbox with plain `--get-latest` and opens image attachments from their `absolutePath`, which keeps large image data out of a bot's context.

### Fixed

- Interrupt a busy bot when a message asks it to stop, even when Apple Intelligence is slow to start. Automatic delivery gave the model 10 seconds to decide, which a cold model often missed, so the message waited for the turn to finish. It now has a minute.
- Check OpenCode's latest release again in Settings > Harness. Noodle rejected the provider's release information whenever its rollout flag was off, so OpenCode showed "Could not check the latest release" and never offered an update.
- Reclaim the partial files of a local model download or import that was interrupted by a crash or force quit. Noodle now deletes them at launch and before the next download or import, so they no longer hold disk space or count against the free-space check.
- List a local model whose stored information is damaged as Unreadable Model in Local Models so its weights can be removed; it previously disappeared from the list while staying on disk.
- Stop restricted FX bots from logging a "skill discovery warning" on their first prompt. FX reported every account folder above the workspace that the sandbox hides, such as `~/.claude/skills`, as bot output. Noodle now leaves those out of the activity log and still shows problems with the bot's own skills.
- Limit the height of the affected-bots list that opens from a harness's status in Settings > Harness and scroll it when many bots need a kick; it previously grew past the screen with no way to reach the bots at the bottom.
- Keep each harness's buttons on one line in Settings > Harness. Sign In previously sat on its own line below Profiles, Update and Remove.

## [0.20.0] - 2026-09-19

### Changed

- Move Noodle Browser's Create button into the sidebar's toolbar, after the sidebar toggle and apart from Back and Forward; it hides with the sidebar.
- Move the Create button into the sidebar's toolbar, after the sidebar toggle, on macOS 26 and later; it returns to the window toolbar while the sidebar is hidden.
- Move Noodle Applet's Open Noodlet button into the sidebar's toolbar, after the sidebar toggle, on macOS 26 and later; it returns to the main toolbar while the sidebar is hidden. It now uses the suite's plus icon.
- Move Noodle Browser's Edit Browser button after the view picker, beside Mute and Pause Agents.
- Tighten the corner radius of Noodle Browser's content panel and selected tab so each sits evenly inside the corner around it.
- Give Noodle Browser's History and Bookmarks a larger, rounder search bar, and replace the bookmark plus button with an Add button, and drop the ellipsis from History's Clear button.
- Open Noodle Browser's History and Bookmarks entries in a new tab instead of replacing the page in the current tab.
- Give Noodle Browser's Downloads the same search, list and paging as History and Bookmarks.
- Delete single Noodle Browser history entries and downloads from their right-click menus, alongside the bookmark Edit and Delete items; every delete asks for confirmation, and deleting a download also removes its stored file. Clicking a completed download saves it.
- Make Noodle Browser's address bar wider and slightly taller.
- Keep Noodle Browser's bookmark Add button enabled on a blank tab, where it starts an empty bookmark.
- Open Local Models with the installed models and the last known support check already in place instead of a brief checking state, and animate the sheet when its height changes.
- Remove the sharing note below the bot editor's Computers list.
- Replace the bot editor's Effort slider with a glowing gradient track whose colour and sparkles build as the effort rises. It snaps to each supported effort, stays still with Reduce Motion, and remains a standard slider to VoiceOver.
- Start Create Image from the still conversation background being previewed, however it was chosen, instead of only from Photos and generated images.

### Added

- List the macOS permissions Noodle uses in a new Settings > Permissions tab: Microphone, Screen Recording and Notifications, each with whether it is allowed. A permission macOS has not asked about yet has a Request button; one that was refused opens its System Settings pane. The tab is badged with the number of refused permissions on macOS 26 and later; permissions never requested are not counted. Statuses are rechecked when Settings opens and when Noodle becomes active again.
- Show when a newer Noodle is available in Settings > Update, and badge the Update tab on macOS 26 and later. Noodle asks its updater when Settings opens, without offering the update; versions you chose to skip are not announced.
- Badge the Harness and Tools tabs in Settings with the number of harnesses and tools that need attention on macOS 26 and later. A harness counts for a failed check, a failed bot, a required update, or an available update; a tool counts when its row shows Needs attention. Harnesses are now checked when Settings opens instead of when the Harness tab is first selected; harnesses that are not installed or not signed in are not counted.
- Show when an installed companion app has a newer release in Settings > Companions, beside its version, and badge the Companions tab with the number of companions that are behind on macOS 26 and later. Noodle reads each companion's own update feed when Settings opens, at most every six hours, or on Check Again; the companion still installs its own updates, and builds with updates turned off are not checked.
- Give each Noodle Browser an optional description of what it is for. Assigned bots receive it with the browser's name from `browser list` so they choose the right browser; the bot editor's browser picker shows and searches it. Page-preview cards never include it.
- Open a new tab by double-clicking the empty space in Noodle Browser's tab bar; double-clicking a tab still only selects it.
- Choose a macOS system wallpaper as a background in Noodle, Noodle Browser, Noodle Computer and Noodle Applet. Choose Background opens a System Wallpapers dialog showing thumbnails of the wallpapers already on this Mac, including dynamic ones, macOS's bundled video wallpapers and downloaded aerials, which play as animated backgrounds; clicking one chooses it. Wallpapers that System Settings has not downloaded are left out, and a Wallpaper Settings link opens System Settings to download more; the dialog refreshes on return. Reading downloaded wallpapers adds read-only sandbox exceptions for macOS's downloaded-wallpaper and aerials folders.

### Fixed

- Keep Noodle Browser, Noodle Computer and Noodle Applet out of the Dock and app switcher when Show in Dock is off; opening one of their windows or a request from Noodle no longer brings the Dock icon back.
- Keep the Read more reader open after saving an annotation so more annotations can be added.
- Keep Noodle Browser's Downloads title at the same height as the History and Bookmarks titles so it no longer shifts when switching views.
- Build Noodle Applet with the selected Xcode SDK recorded in the app, so builds made with Xcode 27 keep the current macOS appearance instead of falling back to the legacy one.
- Import bot icons from Photos items that do not offer generic data, using the same image transfer as backgrounds.
- Keep the bot icon editor's Done button disabled while a chosen image is still loading, so it cannot save the previous icon.

## [0.19.0] - 2026-09-18

### Changed

- Keep long user and bot messages compact with a Read more popover, and turn large text pastes into text attachments without replacing the draft.
- Move affected-bot details and Kick actions in Harness Settings into a popover opened from the harness status label.
- Give the website’s reusable MacBook image a blank black display while retaining the separate screen overlay.
- Make DMGs the primary release-page and website downloads, with ZIPs retained as an alternative.
- Clarify Browser skill sharing choices, put clickable page previews near the top, and direct agents to current help before claiming a capability is unavailable.
- Use Computer’s shared assignment picker for bot browsers: Add Browsers, searchable choices, circular custom icons and removable assigned items.
- Simplify Noodle Browser creation and use independent per-browser backgrounds with the suite’s appearance controls.

- Align Noodle Browser with Computer and Applet: sidebar-based browser selection, suite appearance, native menus and matching Settings/Update flow.

### Added

- Add a Noodle Suite installer assembled from published app releases, with checksum-verified archive caching and reuse of unchanged Suite snapshots.
- Let agents discover and invoke website WebMCP tools through the Browser CLI or JavaScript, with authenticated sessions, JSON arguments and explicit human form handoffs.
- Ship a signed, notarized DMG alongside the ZIP, with large app and Applications icons and a drag-to-install layout.

- Give browser agents virtual mouse commands for element hovering and clicks, with pointer state in CLI responses and guidance in the managed Browser skill.
- Document Noodle Browser setup and connect its releases to the suite's shared publication and recovery process.
- Add OpenCode v2 with its official logo, native installation and version checks, model/effort selection, ACP session recovery, and restricted per-bot credential, database, and cache storage.

- Let agents present browser pages as preview attachments that open the saved page in its assigned Noodle Browser profile, with separate Dev/normal reference files.
- Add standalone symbol SVGs and automatically compose the full icon SVG, PNG sizes and packaged macOS icon on every build.
- Add Noodle Browser’s Build & Launch Dev Runbar entry, matching Computer and Applet.
- Add Noodle Browser: create persistent WebKit browsers, sign in and assign them to bots, with background scripting, screenshots and workspace file transfers.
- Let bots search their assigned browsers’ persistent history and manage bookmarks through Noodle Browser, with separate Dev and normal app packaging.

### Fixed

- Support selected-text annotations and the Annotate Region shortcut inside long-message reader popovers.
- Prevent intermittent Computer lifecycle test timeouts when mailbox change notifications arrive after the initial request scan.
- Require a focus click before interacting with an inactive window's content, preventing accidental link and attachment opens in conversations.
- Let Browser scripts and WebMCP argument files be read directly from the bot's workspace while rejecting symlinks, oversized files and paths outside it.
- Report OpenCode’s structured provider failures accurately while preserving the saved session and unfinished work for Kick recovery.
- Wait for OpenCode’s online model catalogue refresh so newly available models appear in the picker and can be selected when a bot starts.
- Align the conversation transition surface with the transcript's coordinate system to prevent vertically mirrored message text, retaining the existing Markdown renderer and text selection.

## [0.18.1] - 2026-09-17

### Fixed

- Clear unread indicators immediately when focusing or interacting with a conversation in the main window or a popped-out chat, including clicks, scrolling, typing, gestures, attachment drops, sends, and incoming replies while that chat is active.
- Shorten the conversation's top shadow and content fade to keep the header avatar clearer while preserving the soft toolbar transition.
- Keep helper processes and standalone UI test fixtures out of the Dock and app switcher by default.

## [0.18.0] - 2026-09-17

### Added

- Add JavaScript workflows to `mcpshim` with macOS JavaScriptCore, synchronous MCP calls, JSON output, console diagnostics and error traces, workspace file support, and bounded execution without an additional runtime.
- Add an Apps switch beside Unrestricted in Sandbox settings for Codex and Claude Code. Account apps default to off, are remembered separately for each bot and harness, and have a clickable explanation and lowercase access status.
- Add Gmail MCP connections for reading mail, creating drafts and managing labels, with native Google sign-in and separate accounts. Mark experimental integrations and list them last in the catalogue.
- Add separate experimental Google Docs, Drive and Calendar MCP connections for document editing, file access and creation, and calendar event management.

### Changed

- Use Dev names for development apps, sharing links and Runbar entries, and export development Computer attachments as `.noodlecomputer-dev`.
- Rename Security settings to Sandbox, make the Unrestricted heading open its explanation, and add a matching clickable Heartbeat heading above the bot switches.
- Consolidate MCP connection, catalogue and Google Workspace documentation into one guide.
- Keep documentation public-facing, consolidate gateway guidance, and remove internal review and debugging narratives from user guides.

### Fixed

- Prevent an exiting harness from terminating Noodle when the app writes to its input pipe.
- Restore cached link preview titles and images immediately when conversation rows reappear, without replaying the loading animation.
- Pair Noodle Dev only with Applet Dev, preserve applet link environments in conversations, and generate local document and CLI guidance for local bots.
- Pair Noodle Dev exclusively with Noodle Computer Dev for discovery, document opens and authenticated connections, keeping development computers separate from the installed apps.
- Restrict development launchers and the local installer to isolated app identities; remove the production-data launch option.
- Reduce idle CPU usage by scanning bot mailboxes when their directories change, with periodic recovery checks instead of repeated idle directory walks.
- Show MCP HTTP failures and actionable access errors instead of directing failed connections back to the same Settings screen.

### Removed

- Remove the development registration audit and dated MCP gateway notes, repairing their documentation links.

## [0.17.0] - 2026-09-16

### Added

- Save MCP binary results as workspace files automatically, accept `@file` JSON input references (`@@` for a literal `@`), and expose resource listing/reading with `--raw` result output when needed.
- Open bot profiles from member avatars in New Group and Group Info, with Message and Edit actions, and confirm before removing a member with the X button.
- Show clickable bot avatars in Security and Heartbeat settings, opening the existing profile with Message and Edit actions.
- Enable restricted Claude Code bots with private login and session storage, normal native tools under Noodle's process sandbox, and a working unrestricted-access switch. Verify native startup, tools, Messenger, outside-file denials, and resume with an offline API fixture.

### Changed

- Widen Settings so all tabs fit alongside the Conversation label.
- Rename the Chat settings tab to Conversation to match the menu.
- Remove the Bots heading from Heartbeat settings.
- Rename Autonomous access to Unrestricted across settings, runtime messages, and current documentation. Keep the orange label and make both access labels open a popover explaining their permissions.

### Fixed

- Restore popped-out conversations and their window positions and sizes after quitting or unexpectedly exiting the app, while keeping explicitly closed windows closed.
- Prevent false Claude Code “Update required” warnings when its help output is truncated through a pipe, and treat oversized help as an incomplete check instead of missing support.
- Fix local and Runbar launches stopping after packaging when Agent Host verification encounters a broken pipe.
- Recheck Applet broker sessions and conversation access after asynchronous work, preventing queued requests and result payloads from surviving access revocation.
- Keep background changes in Edit Bot and Group Info pending until Save, discard them on Cancel, and preserve the original background if saving settings fails.

## [0.16.2] - 2026-09-16

### Changed

- Simplify the website to one landing page with native system typography, a centered MacBook preview, a Download button, and a smooth dark gradient.
- Give activity windows the preview panel’s rounded frame and single close control, with edge resizing and no maximise, minimise, or full-screen actions. Keep compact logs, context-menu commands, and plain-dash titles.

### Added

- Drop images and videos from Finder or a browser directly onto the conversation background preview, including direct media links, using the same importer and drop target as Computer and Applet.
- Show a bot’s live activity in a floating log window from its context menu, with recent in-memory history, selectable output, and context-menu commands to copy, clear, and follow the log.

### Fixed

- Keep the composer avatar fix compatible with macOS 26 SDK builds used by release validation.
- Remove development-only Metal toolchain framework search paths from packaged apps.
- Prevent release checks from failing with broken-pipe errors while verifying updater signatures and bundle linking.
- Label Apple/local-model turn setup as “Preparing turn” so cached model reuse is not reported as a fresh model load.
- Suppress settings scrollbar flashes during tab changes and dynamic window resizing on macOS 27, restoring indicators after the layout settles.
- Show Apple/local-model tool calls, command output and exit status, file errors, durations, and recovery steps in the Activity window as they happen.
- Disable Writing Tools in the message composer to suppress the floating Siri control on macOS 27.
- Load the workspace's complete `AGENTS.md` and discover skill names, descriptions, and paths on every Apple/local-model wake, including resumed sessions. Include managed and user-created skills in the system instructions while leaving full skill instructions available to read on demand.
- Let Apple turns continue while generation or tools make progress, with a five-minute inactivity timeout and a 30-minute overall limit. Resume interrupted local-model work with recovery settings, bound optional thinking attempts, and preserve history when summaries fail.
- Recover empty or truncated Apple/local-model replies in the existing session, preserve completed tool results, and disable optional MLX reasoning during recovery. Bound generation loops, warn on repeated actions, and checkpoint tool rounds before continuing.
- Recover bots after saving tool or computer assignments during active work: wait for runtime shutdown to finish and let Kick retry an unconfirmed stop while preserving the session and unfinished work.
- Restore bot avatars in the composer @ menu on macOS 27.

## [0.16.1] - 2026-09-15

### Changed

- Replace Image layout with Attachment layout for all message attachments, including annotations, documents, and voice messages, with Wrap as the default and Vertical and Stack options.
- Give every Apple harness turn `bash`, `read`, and `write`, with shared CLI access for Messenger and assigned tools. Always resume and manage the saved session; remove the dedicated history tool and request classifier that could fail before replying.
- Simplify Apple instructions around performing requests with current tools, keeping new requests separate from summaries of earlier conversation.

### Fixed

- Include every Apple runtime regression suite in the macOS 27 CI checks.
- Confirm local model removal before deleting its files, and recheck bot assignments when removal is confirmed.
- Explain local model usage in a popover with direct access to each bot’s Harness settings, an updated assignment list after editing, and removal once no bots use the model.
- Keep trailing decimal zeros and use monospaced digits in model download progress to reduce label movement.
- Preserve Apple command results after a later generation fails and when resuming interrupted turns. Reserve space for native tool continuations, finish from existing results when a tool sequence fills the budget, and avoid redundant inbox checks for supplied chat messages.
- Remove instructional footer labels from the screen and window capture picker.
- Reuse a single main window when launching or reopening Noodle, preventing duplicate conversation lists while preserving separate chat windows.

### Added

- Download recommended MLX models directly from Apple Intelligence’s Local Models settings, with size and source details, progress, cancellation, and verified imports.
- Navigate the screen and window capture picker with arrow keys, keep the highlighted source in view, and press Return to preview it.

## [0.16.0] - 2026-09-15

### Added

- Open a bot’s editor from its profile, with Reply, Message, and Edit arranged in one compact action row.
- Show the active Apple model and its capabilities on macOS 27, analyze image attachments, and require a tool call for workspace tasks before allowing a final reply.
- Import and select local MLX Qwen2, Qwen3, and Llama text chat models in Harness settings on macOS 27, with private model storage and offline loading inside the restricted helper.

### Changed

- Use Apple's Foundation Models Utilities history helpers on macOS 27 to summarize Apple Intelligence workspace conversations and trim completed tool exchanges, while retaining token limits and macOS 26 support.
- Use a plus icon for the toolbar's Create menu.
- Name the Spotlight, Shortcuts, and contextual Services actions Send to Agent, with an Agent or Group picker, a Message field, and Send to Bot search keywords and invocation phrases.
- Remove bot profile button backgrounds and show vertical separators only between actions.
- Make the Local Models dialog narrower than Settings, with one short import hint, a compact model list, and a separate action footer.
- Encourage Git checkpoints in the applet skill, with the repository root above the `.noodlet` folder to keep Git metadata out of imported packages.

### Fixed

- Drag voice-message attachments from the entire control, including the waveform and padding, while keeping click-to-seek and play/pause available.
- Detect harness updates when release metadata exceeds 256 KiB, retain a 2 MiB download limit, and show update-check failures in Harness settings.
- Replace cached harness update-check errors with Checking for updates while a fresh check is running.
- Place the Official Update Guide button beside Open Terminal in harness update instructions.
- Group bot-specific harness errors and reconnecting messages below the harness details and actions, separated by a divider for every provider.
- Explain how to install the selected Xcode's missing Metal Toolchain when a local build cannot package MLX shaders.
- Show Codex connection retries as amber Reconnecting status with elapsed time and Kick in Harness settings. Recover after ten minutes without progress, preserving unfinished work and requiring a confirmed stop; pause after two unsuccessful automatic restarts.
- Build Noodle releases with the macOS 27 SDK and include MLX shaders even when the build host runs macOS 26.
- Budget Apple model context before every generation on macOS 27, including tool continuations, with bounded history and tool results, image sizing, and room for replies. Recover image chat from context-limit errors without replaying workspace actions.
- Use the canonical helper cache path for MLX shader compilation and delegate only that cache and read-only bundled resources to Apple's Metal compiler.
- Run the macOS 27 Apple harness CI checks only when the runner has a compatible OS and SDK, with an explicit skip reason on older runners.
- Fit the Tools settings list to its content, removing excess space below connection buttons while keeping long lists scrollable.
- Keep tool sign-in progress and Cancel in the action row, with the sign-in message in the existing status line to prevent layout shifts.
- Preserve the selected SDK throughout local builds, fixing Settings resizing and legacy macOS appearance after rebuilds. Reject app packages with mismatched SDK metadata.
- Accept Markdown, text, source code, and other file types dropped into conversations, including directly onto the message input.
- Keep explicit Apple harness tool requests out of the tool-free chat recovery path.
- Refocus the chat input after saving a text or region annotation in the conversation window, ready to submit the draft.

## [0.15.0] - 2026-09-14

### Added

- Drag conversation attachments and draft attachment chips into Finder, other apps, or another conversation, preserving their filenames and keeping the originals in Noodle.

### Changed

- Explain account-backed Local Mac computers and their workspace paths in the assigned-agent Computer instructions.

## [0.14.0] - 2026-09-14

### Added

- Add a concise enterprise introduction for prospective customers highlighting the benefits of native macOS integration, managed deployment, on-device AI, and connected business tools, linked from the README and documentation index.

- Cover saved annotation preview editing, repeated saves, cancellation, blank comments, failed-save retry, read-only sent notes, original-conversation routing, missing images, and current/legacy image rendering with hidden native panels.

- Cover saved general, chat, microphone, and heartbeat preferences with hidden-window tests, including native toggle and segmented-control changes, settings reopening, runtime recreation, and disconnected microphone recovery.

- Cover native bot harness/model/effort selection, model search, default choices, creation, unavailable-harness validation, and preservation of saved settings with hidden-window tests.

- Cover bot editor save, failed-save retry, blank-name validation, and cancel through native controls in hidden test windows.

- Add persistent `preferences.md` to new and existing bot workspaces, initially containing only a `# Preferences` heading. Keep usage guidance in generated `AGENTS.md`, preserve existing contents across refreshes, and load preferences alongside backstory in Apple.

- Teach assigned agents to automate the Computer desktop's visible, signed-in browser using bundled Puppeteer, hand sign-in to the user, and disconnect without closing shared tabs.

- Cover draft-safe message failures, attachment-only sends, independent voice and command sends, reaction edits, and unread persistence through the app store.

- Cover group creation, edits, deletion, participant wakeups, and conversation search through the app store with isolated workspaces.

- Cover heartbeat deadlines, busy-bot deferral, activity resets, settings changes, and relaunch persistence with an injected clock.

- Cover bot startup, workspace validation, restart stop-confirmation, shutdown, configuration changes, and session reset with isolated runtime fixtures.

- Add MCP controller regression tests for saved-account failures, bot assignment isolation, forged and replayed bridge requests, and browser sign-in validation, cancellation, and timeout recovery, without provider accounts or Keychain access.

### Fixed

- Keep complete mailbox messages readable during atomic replacement, while continuing to reject linked files. Exercise the production mailbox and composer in fixtures, and link native tests against current build outputs and bridge dependencies instead of stale object files.

- Repair native fixture startup and close inherited IPC pipes during teardown so harness restarts can release their previous sessions.

- Update runtime recovery messages and help to point to Kick in Harness settings, and align harness setup documentation with Apple Intelligence.

- Open Computer attachments with the running provider, or the neighbouring local Computer build during development, instead of an older installed copy that cannot handle reference files.

- Correct Computer skill and CLI guidance: attachments show saved previews and open the computer's normal desktop or human terminal, rather than resuming an agent's terminal session.

- Avoid overlapping Quick Look loads when opening or repeatedly clicking attachments, and keep unavailable thumbnails retryable instead of caching a generic file icon.

- Reuse the saved preset account when tool creation retries a failed workspace refresh, including after switching presets. Preserve independent accounts for separate creations and cover catalogue search, custom setup navigation, repeated clicks, cancellation, and save failures with hidden-window tests.

- Stop old voice playback and clear its error when a message's recording changes, load the replacement recording, and reset the displayed playhead immediately on replay. Cover pause/resume, seeking, completion, failures, active-message handoff, and view removal with silent playback fixtures.

- Reset reused link-preview cards when their URL changes and ignore results from the previous request. Cover shared requests, cached failures, metadata/image deadlines, cancellation, and visibility with controlled loaders and hidden views.

- Keep a new MCP connection's identity across failed workspace-refresh retries and pass the saved account, including its allocated skill name, to completion and sign-in callbacks. Cover connection validation, editing, assignments, cancellation, and retry with hidden-window tests.

- Preserve group metadata and member inbox positions when an edit cannot save every file, and retain the membership notice for a successful retry. Cover group search, membership controls, creation, validation, cancel, and failed-save retries with hidden-window tests.

- Clear cancelled harness sign-ins immediately so users can retry, and ignore retired challenges and account checks. Bind setup results to the current installation so removed or replaced harnesses cannot be restored by a late callback. Discard version results returned after cancellation.

- Cancel an unfinished capture-region drag when the image or selection mode changes, so mouse-up cannot annotate a replacement capture. Cover native capture-window close/reopen, keyboard save retries, permission recovery, and original-conversation routing.

- Keep runtime errors and recovery actions in Harness settings, removing duplicate warnings and Retry Startup buttons from Security settings.

- Add a blank line between companion headings and their paragraphs in generated `AGENTS.md` instructions.

- Reject uploads and downloads when Computer access is revoked during the final provider handshake, and withhold catalogue and transfer results from retired bot sessions after removal or restart.

- Discard annotation preparation results after close, navigation, or replacement, and prevent retired region canvases from modifying a newer draft. Report missing attachments before opening Quick Look; cover preview ownership, save retries, sent-note protection, and missing-image failures with hidden-window tests.

- Restore prior bot settings and assignments when an edit fails, and grant a newly selected harness only after saving succeeds. Remove incomplete bot creations, preserve bot access on failed deletion, and restore staged workspaces and conversations if deletion cannot update every group. Keep successful saves distinct from Messenger startup failures.

- Recheck Computer access after provider discovery and before terminal actions, retain newer discovery results over late responses, retry failed bridge-session writes, and always schedule terminal revocation after assignments are saved. Cover these races and uncertain-command delivery with controlled broker tests.

- Keep runtime startup failed when a Codex session cannot be saved, scope approvals and callbacks to their active turn and connection, and prevent late Claude stop confirmations from overwriting restarted status. Bound Codex and Claude helper startup waits; cover Codex, Claude, and ACP recovery, cancellation, permissions, and transport failures in SwiftPM.

- Make Kick explain account failures and ask before recovering a missing Grok session from conversation history. Preserve previous session references, files, settings, and unfinished work, and pause interrupted recovery until an explicit retry.

- Keep region-annotation previews the same height before and after thumbnails load, preventing transcript rows from jumping during scrolling. Add real-thumbnail and full-chat layout regressions, and make transcript fixture timeouts detect a blocked main thread.

- Clear Muse’s paused-runtime liveness after an explicit stop. Cover session resume, early turn completions, steering, staged approvals, and bounded history recovery in the default Swift test suite without a Muse account.

- Discard late share-provider results after cancellation or replacement, and give each load its own draft so older callbacks cannot append to or remove the current share.

- Prevent cancelled share composers from publishing content or recreating their drafts. Cover text/file sharing, duplicate filenames, and publication retry without opening the extension UI.

- Preserve unreadable conversation history instead of replacing it during a send. Report the failure and retain the unsent text and attachments for retry.

- Bind stop confirmations to the exact restart or access-change operation so a late confirmation cannot grant access or launch an outdated configuration during a newer transition.

- Ignore status, approval, and heartbeat callbacks from retired runtimes, keeping restarted and removed bots isolated from late process events.

- Cancel pending runtime recovery when a bot leaves the roster so delayed restarts cannot bring it back. Cover crash backoff, stable-runtime reset, wake recovery, and shutdown with controlled timers.

- Restore restricted Codex HTTPS connections with a host-prepared public certificate bundle, preserving the sandbox and Keychain restrictions. Show active Codex connection failures and retries in bot status and lifecycle logs instead of leaving the bot silently busy.

- Pause Grok bots when their saved session cannot be found, show the storage problem and recovery action, and preserve the session reference and unfinished work instead of repeatedly restarting with a sign-in warning.

- Let conversation participants target the exact Applet session returned by shared opens using the shared link, conversation, and session ID together. Document hidden rendering limits, session diagnostics, and explicit headless animation stepping in generated CLI help and agent guidance.

### Changed

- Remove the Preview menu; annotation actions remain available in Conversation and through keyboard shortcuts.

- Show saved images for Computer attachments and open the referenced computer in Noodle Computer when clicked, keeping agent assignment checks on the CLI path.

- Remove unused in-chat action approval and question forms, their pending-request queue, and sidebar indicators. Keep runtime permission replies tied to saved bot access, skip structured questions immediately without adding a replacement prompt.

- Display the Apple harness as “Apple Intelligence” in settings and harness selections.

- Store Backstory privately in `agent.json` and generate all of `AGENTS.md` without section markers, warning that edits are overwritten. Migrate existing backstories once before regeneration, preserve damaged sources for recovery, and register 0.14.0 as the migration milestone with conditional cleanup after it.

- Publish Noodle as `Noodle-arm64.zip` with a matching checksum so the website can link directly to the latest download. Preserve existing migration-release downloads and defer website deployment until its download is available.

- Skip app CI for ordinary Markdown, documentation assets, and website-only changes. Skip image builds and website deployment for README-only edits, while retaining checks for release metadata and the generated message reference.

## [0.13.0] - 2026-09-13

### Fixed

- Run sandbox and broker regressions on ordinary CI pushes as well as pull requests and releases. Require freshly built, ad-hoc signed CLI fixtures without developer credentials, include adapter session recovery checks, and cover membership revocation, cross-bot tokens, and invalid mailbox inputs.

- Make the paused-capture regression deterministic so delayed CI scheduling cannot race its simulated pause against the preview acceptance timer.

- Highlight autonomous access in orange in Security using the same regular caption weight as other settings labels, keep restricted access neutral, and move the Claude Code access requirement into a popover opened from its label.

- Isolate restricted bots from other bots’ files, raw conversation storage, and shared harness histories. Broker Messenger access by bot identity and conversation membership, copy attachments into each workspace, give cloud harnesses private credential/session stores, and prevent workspace symlinks from redirecting app-side bridge or skill writes.

- Correct the README's restricted-harness list and document how the sandbox is enforced, what it protects, and its limits around shared data, networking, tool access, and resource use.

- Keep the Applet catalogue closed when loading a conversation's noodlet attachment previews. Use a dedicated background URL so sandboxed launches preserve the request, including when the companion is already starting.

- Prevent conversation annotation updates from reattaching to a window during teardown and crashing Noodle.

- Display the bot or group name as plain title text in separate chat windows, removing the small glass capsule on macOS 26.

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

- Add restricted sandbox support for Muse Code, with optional autonomous access. Keep restricted Muse sessions and runtime files inside the bot workspace while using its existing login and preserving once-only staged tool approvals.

- Add restricted filesystem sandboxes for FX and Grok Build, with optional autonomous access in Security. Permit workspace files, Messenger replies, and the selected harness's account/session storage while protecting bot configuration, Noodle runtime state, unrelated files, and harness installations.

- Open any bot chat or group in a separate window from the sidebar. Keep messages, drafts, attachments, and conversation details synchronized while browsing and scrolling independently.

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

- Remove the Open in New Window button from the chat toolbar; the action remains available in the sidebar context menu.
- Dissolve between conversations without a blank flash, preserving the text editor and keyboard focus while switching drafts and voice recorders, and respecting Reduce Motion.
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

[Unreleased]: https://github.com/pdparchitect/noodle/compare/v0.18.1...HEAD
[0.18.1]: https://github.com/pdparchitect/noodle/compare/v0.18.0...v0.18.1
[0.15.0]: https://github.com/pdparchitect/noodle/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/pdparchitect/noodle/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/pdparchitect/noodle/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/pdparchitect/noodle/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/pdparchitect/noodle/compare/v0.11.2...v0.12.0
[0.9.0]: https://github.com/pdparchitect/noodle/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/pdparchitect/noodle/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/pdparchitect/noodle/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/pdparchitect/noodle/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/pdparchitect/noodle/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/pdparchitect/noodle/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/pdparchitect/noodle/releases/tag/v0.3.0
