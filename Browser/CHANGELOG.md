# Changelog

## [Unreleased]

### Added

- Clicking a file button in a tab you can see opens the Mac file picker, and dropping a file on the page attaches it. When someone is watching the tab, the picker opens for them instead, on their Mac or iPhone.

## [0.22.3] - 2026-10-28

### Changed

- The Edit Browser toolbar button uses a plain pencil icon.

### Improved

- A tab unused by agents for five minutes now releases its hidden rendering window while keeping the page and unsaved edits alive. It resumes when an agent uses it or you watch it live; pages in the browser window and those busy with an operation, dialog or upload stay attached.
- Browser frees cached page resources when the Mac is short of memory, keeping current pages, sign-ins and unsaved edits open. Going Back may reload a page whose cached copy was freed.

## [0.22.2] - 2026-10-28

### Fixed

- Video and audio in a tab nobody has used for 10 minutes are now paused where they are, and pick up from there when you or a bot use the tab again. Some pages kept their players busy for hours after a bot left them, slowing the whole Mac. Tabs you're watching live or have open in a browser window keep playing.

## [0.22.1] - 2026-10-26

### Fixed

- A tab that a bot's page opens, such as Apply on a job listing, now belongs to that bot, so the bot is told when it goes unused and can close it. Before, these tabs piled up until the browser reached its 100-tab limit.

## [0.22.0] - 2026-10-24

### Added

- A bot is told about tabs it opened and then left unused for six hours, in one note listing them, so it can close the ones it no longer needs. Each tab is mentioned once until it is used again. Tabs you opened are never mentioned, and tabs still close after the days set in Settings › General. Needs a Noodle or Noodle Hub that says which bot opens a tab.

### Fixed

- Clicking back into a window no longer leaves it ignoring every click until you move it. When macOS didn't bring the app forward on the first click, the next click now goes through.

## [0.21.5] - 2026-10-23

### Fixed

- A popup from a bot's page past the 100-tab limit no longer shows you an alert when the browser window shows the bot's tab. The bot is told to close tabs it no longer needs and try again.
- Nothing flashes on screen anymore while a bot uses a tab, such as a page's note about a form field the bot left empty. Tabs bots use stay fully out of sight.

## [0.21.4] - 2026-10-22

### Fixed

- Noodle Browser no longer grows in memory after Settings was opened once: the closed Settings window kept updating out of sight for as long as the app ran.

## [0.21.3] - 2026-10-22

### Fixed

- Tabs a bot is using no longer show as empty Noodle Browser windows in Mission Control.

## [0.21.2] - 2026-10-22

### Fixed

- A window no longer flashes on screen when a bot finishes with a tab, closes one, or a person starts watching a browser live.
- A bot opening a tab, or a popup from a bot's page, past the 100-tab limit no longer shows you an alert. The bot is told to close tabs it no longer needs and try again.

## [0.21.1] - 2026-10-21

### Fixed

- Pages a bot is using keep drawing while the browser's window is closed. Sites that wait to draw, such as X's Edit profile dialog, no longer stay empty for bots until someone opens Noodle Browser.
- When a bot's click or script fails on a page, the bot is told why, such as "Element not found", instead of "A JavaScript exception occurred".

## [0.21.0] - 2026-10-20

### Added

- Someone watching a browser live can sign in to the page they see with their device's own fields and saved passwords, once their Noodle or Noodle Hub offers it. Passwords they fill but don't submit are cleared from the page when they stop watching. A page a bot ran its own scripts on isn't offered for signing in until it's reloaded.

### Changed

- The Pause Agents button now sits before Mute in a browser's toolbar.

## [0.20.1] - 2026-10-20

### Fixed

- Muting a browser only silences it. Video keeps playing, so sites that work with video in the page, such as TikTok making a cover for an upload, no longer stall in a muted browser.

## [0.20.0] - 2026-10-18

### Changed

- Bots and other apps can no longer bring a browser's window to the front. Bots attach tabs to conversations instead, and you open a browser yourself.

### Fixed

- A tab that isn't shown in the browser window can no longer appear on the desktop as a bare window showing its page.
- Clicking a page's upload button in a live view no longer opens a file picker on the Mac running Browser. The live view says why the upload did nothing.
- A page that stops responding no longer locks Noodle, the Hub and bots out of every browser until Noodle Browser is restarted, which failed with "Browser connection write failed".

## [0.19.3] - 2026-10-17

### Fixed

- Closed sheets and Settings windows are freed, so the app no longer slows down the longer it runs.

## [0.19.2] - 2026-10-16

### Changed

- Once a browser has 30 tabs, a bot that opens another is asked to close the ones it no longer needs.
- A page that cannot load, or whose process stopped, shows an error page saying what went wrong, with a Reload button, instead of a red line above a blank tab.

## [0.19.1] - 2026-10-16

### Fixed

- A tab whose page was stopped to save memory comes back with its history, so Back still works.
- A link that downloads a file no longer leaves "Frame load interrupted" on its tab.
- Site icons are read only from small PNG, ICO, JPEG, GIF and WebP files; SVG icons are skipped, and a huge or endless icon download is cut off at a megabyte.

## [0.19.0] - 2026-10-15

### Changed

- The background picker offers 40 gradients in place of four, from pastels to neutrals, as a grid of round swatches. Gradients are no longer dimmed, so they show their true colours.
- The shaded band at the top of the window is gone.
- Icon editors show a Picture or Symbol switch, with only that choice's options beneath it, in place of Use Symbol Instead. Switching to Symbol and back keeps the picture until you press Done, and Create Image… reads Edit Image… when there is a picture to start from.

### Fixed

- Browser icons made from your own or generated pictures look smooth at small sizes instead of pixelated.

## [0.18.2] - 2026-10-14

### Fixed

- An app outside Noodle that is turned away is told why, instead of sometimes getting "The connection closed."

## [0.18.1] - 2026-10-14

### Fixed

- The address bar goes back to showing just the domain when you click elsewhere, such as on the tab strip or a toolbar button, not only on the page.

## [0.18.0] - 2026-10-13

### Changed

- A tab that opens, whether you or a bot opened it, scrolls into sight in a long tab strip, as does a tab when it's selected.
- The address bar shows just the site's domain in the middle, as in Safari, and the full address when you click into it. A page button on its left shows the site and whether its connection is secure, and the reload button is bigger.

## [0.17.0] - 2026-10-12

### Added

- You can drop a picture from Finder or a browser onto the browser's icon editor to use it as its icon, as you already could for backgrounds.

### Changed

- Tabs out of sight slow down as they do in Safari, so many open tabs no longer keep the browser busy.
- Each browser keeps at most 8 pages running. The least recently used ones stop but stay open as tabs, and load again when you or a bot use them.

### Removed

- WebMCP form tools (forms marked up with `toolname`). Supporting them meant watching every change on every page, which slowed busy sites down; tools a site registers in JavaScript still work.

### Fixed

- Sites now recognise the browser as Safari, so they serve their full pages instead of reduced or broken ones.
- Pages that change their title often, such as LinkedIn, no longer make the browser sluggish by saving every change straight away.
- Clicking into a window from another app with the trackpad no longer leaves the window ignoring clicks for a while. The sidebar, buttons and everything else could stop responding until macOS gave up waiting for the first click to finish.

## [0.16.2] - 2026-10-12

### Fixed

- A sheet can no longer get stuck on screen after the window it belonged to has gone. Its buttons did nothing and only quitting removed it; such a sheet now closes on its own.

## [0.16.1] - 2026-10-12

### Fixed

- Settings and sheets no longer bounce when you scroll them while everything already fits; only content taller than the window scrolls.

## [0.16.0] - 2026-10-10

### Changed

- Sheets that change size hide their content while they resize, animate to the new size and fade the content back in, as Settings does, and never grow taller than the screen; taller content scrolls, with the scrollbar clear of the rounded corners.
- Settings never grows taller than the screen; a tall tab scrolls.

## [0.15.0] - 2026-10-10

### Changed

- Switching tabs in Settings hides the old tab while the window resizes, then fades in the new one once the window has its size, as in Safari.

## [0.14.0] - 2026-10-09

### Changed

- Settings > Agents shows its setup commands only while Allow agents is on, each behind an Instructions button.

## [0.13.0] - 2026-10-08

### Changed

- Noodle Hub's browsers are in their own space instead of under Hub in the sidebar. Switch with the Spaces menu: Personal (⌘1) for your own, Hub (⌘2) for the Hub's, with a section for each person they are kept for. The menu shows once the Hub keeps browsers on this Mac.
- Settings > External Tools is now Settings > Agents, and the sidebar section for what agents create is called Agents.
- Settings > Agents shows each setup command in full in a box with a copy button, as Noodle's Settings shows installation commands.
- Settings > Agents lists each allowed app as one row with the number of browsers it may use; click it for its switches, or remove it from its `…` menu or the sheet.
- Tabs share the tab bar evenly and keep their width when a page changes its title. After you close a tab, the others keep their size until the pointer leaves the tab bar, so you can close the next one without moving the pointer.
- Tabs show the page's icon, and a spinner while the page loads.
- A browser's context menu separates Pause Agents from Edit Browser and Change Background.

## [0.12.0] - 2026-10-08

### Added

- Agents outside Noodle, such as Claude Code and Codex, can use Noodle Browser through the `noodle-browser` command or as an MCP server. It is off until you turn on Settings > External Tools. You are asked before each app is first allowed in, before it borrows one of your browsers, and before each new browser once it has created 10. Each app sees only the browsers it created or you lent it, and you can change that in Settings. Browsers these apps create are listed under External Tools in the sidebar. You are warned when an app is not from an identified developer, or when it runs whatever it is given, such as Terminal. Bots in Noodle cannot use it.

### Fixed

- Switching to another browser and back shows the page again, instead of a blank panel.
- Clicking a person under Hub only folds or unfolds their browsers, instead of showing "This browser no longer exists."

## [0.11.2] - 2026-10-03

### Changed

- The toolbar's Edit Browser button shows a More icon (…) instead of a settings-like sliders icon.

## [0.11.1] - 2026-10-01

### Fixed

- Noodle Browser starts on a Mac account with a long user name, instead of failing because the connection path is too long. Update Noodle as well.

## [0.11.0] - 2026-09-30

### Changed

- Let a live viewer that fell behind pick up again from a small picture built on what it has shown, instead of a full new picture about 40 times larger. Update Noodle, Noodle for iPhone and Noodle Hub as well.

## [0.10.0] - 2026-09-29

### Changed

- Send sharper live video when a page cannot be captured at full speed, using the whole rate the viewer's connection takes. It used to go at about a third of it.
- Stop live video from stuttering every two seconds on a slow connection: a key frame goes only to a viewer that needs one. Update Noodle and Noodle for iPhone as well, so their live views ask for one when they cannot go on.

## [0.9.0] - 2026-09-29

### Added

- Tabs nobody has used for 7 days close on their own, to free up memory. A tab counts as used when you click or type in it, or a bot or someone watching live uses it. Choose the time, or Never, in Settings > General.

### Fixed

- A page watched live from another device keeps animating, and counts as seen, when no Browser window shows it on this Mac. Games, videos and other animation used to freeze until the window was opened.

## [0.8.0] - 2026-09-28

### Changed

- Under Hub in the sidebar, browsers Noodle Hub keeps are grouped under the people they are for. Needs the latest Noodle Hub.
- The app icon uses Apple's system blue, the same flat blue as the other Noodle apps.

## [0.7.0] - 2026-09-28

### Changed

- Watching the browser live from Noodle Hub runs at up to 60 frames a second instead of 30, costs this Mac less for each frame and, while the picture stays still, sends nothing and checks it only a few times a second, so the picture keeps up with the page better.
- Browsers Noodle Hub keeps for its bots are listed under Hub in the sidebar, apart from your own.
- Browser follows the system's light or dark appearance instead of always being dark. A browser with a background picture or colour stays dark behind it.
- Delete and Delete Browser no longer end in an ellipsis, since they only ask to confirm. Add for bookmarks now does, since it opens the bookmark form.
- Check for Updates, in the app menu and Settings > Update, no longer ends in an ellipsis.
- Buttons that only open System Settings or a web page no longer end in “…”; “…” is kept for commands that ask for something before they act.

## [0.6.1] - 2026-09-27

### Fixed

- Lighten live video when Noodle Hub says the viewer's connection is slow, so the view keeps up instead of stuttering.
- Live video keeps a steady frame rate, and the app stays responsive while someone watches. Encoding each frame no longer holds up the app.

## [0.6.0] - 2026-09-26

### Added

- Let Noodle Hub show a browser live to the person who owns it, its tabs above the page as in its window, with back, forward, reload and an address bar under them, and take their clicks, typing and scrolling, even while bots are paused. Clicking the tabs selects, closes and opens them, so a link that opens a new tab shows up there, and a new tab starts with its address bar ready to type.
- Let Noodle and Noodle Hub make, rename and delete browsers, so you can set up a bot's browser without switching apps. Bots themselves still cannot.

### Changed

- A request from a newer Noodle or Noodle Hub that this version cannot read says to update Noodle Browser, instead of that the data could not be read.
- Stream live views to Noodle Hub as video, pushing each picture as soon as it is ready, at the size of the viewer's window, and skipping old pictures for a viewer that falls behind. While someone watches a browser, bots cannot use it until they close the view.

### Removed

- Stop opening .noodlebrowser files. Noodle shares tabs as links now, which open the browser and the tab a bot shared.

### Fixed

- Opening the app again brings the copy already running to the front instead of starting a second one on the same data, however it is started.

## [0.5.1] - 2026-09-24

### Fixed

- Keep the bot's pointer above the whole page. Built with the macOS 27 SDK, WebKit adds colour strips along the page's edges, which covered the pointer there.

## [0.5.0] - 2026-09-21

### Added

- Check for updates when Noodle's Settings > Companions asks: its Update action opens Browser and starts the check.

## [0.4.0] - 2026-09-21

### Changed

- Rename the Settings > Update button to Install Update… once a newer version is found. The app menu keeps Check for Updates….
- Leave development-only test modes out of released builds. The checks that release preparation runs against the packaged app are no longer named in it.

## [0.3.0] - 2026-09-20

### Changed

- Accept connections from Noodle's bundled Browser tool extension as well as from Noodle itself. Both are checked by code signature and build channel, and Noodle still decides which browsers a bot may use.

### Fixed

- Keep the App Settings button at the end of the toolbar when no browser is selected, instead of beside the sidebar.

## [0.2.0] - 2026-09-19

### Added

- Show when a newer version is available in Settings > Update, and badge the Update tab on macOS 26 and later. The app asks its updater when Settings opens, without offering the update; versions you chose to skip are not announced.
- Add an optional description of up to 500 characters to each browser in its editor. Assigned bots see it alongside the name when choosing a browser, the sidebar search matches it, and page-preview cards leave it out.
- Open a new tab by double-clicking the empty space in the tab bar; double-clicking a tab still only selects it.
- Choose a macOS system wallpaper as the background. Choose Background opens a System Wallpapers dialog showing thumbnails of the wallpapers already on this Mac, including dynamic ones, macOS's bundled video wallpapers and downloaded aerials, which play as animated backgrounds; clicking one chooses it. Wallpapers that System Settings has not downloaded are left out, and a Wallpaper Settings link opens System Settings to download more; the dialog refreshes on return. Reading downloaded wallpapers adds read-only sandbox exceptions for macOS's downloaded-wallpaper and aerials folders.

### Changed

- Move the Create button into the sidebar's toolbar, after the sidebar toggle and apart from Back and Forward; it hides with the sidebar.
- Move the Edit Browser button after the view picker, beside Mute and Pause Agents.
- Move the App Settings button, shown when both Show in Dock and Show in Menu Bar are off, to the end of the toolbar instead of between Forward and the address bar.
- Tighten the corner radius of the content panel and selected tab so each sits evenly inside the corner around it.
- Give History and Bookmarks a larger, rounder search bar, and replace the bookmark plus button with an Add button, and drop the ellipsis from History's Clear button.
- Open History and Bookmarks entries in a new tab instead of replacing the page in the current tab.
- Give Downloads the same search, list and paging as History and Bookmarks.
- Delete single history entries and downloads from their right-click menus, alongside the bookmark Edit and Delete items; every delete asks for confirmation, and deleting a download also removes its stored file. Clicking a completed download saves it.
- Make the address bar wider and slightly taller.
- Keep the bookmark Add button enabled on a blank tab, where it starts an empty bookmark.
- Start Create Image from the still image being previewed, however it was chosen, instead of only from Photos and generated images.
- Explain that an iCloud photo may need downloading when Photos cannot provide the chosen background.

### Fixed

- Stay out of the Dock and app switcher when Show in Dock is off; opening a window or a request from Noodle no longer brings the Dock icon back.
- Keep the Downloads title at the same height as the History and Bookmarks titles so it no longer shifts when switching views.
- Read a chosen icon image in the background, so a large file no longer freezes the icon editor.
- Say that an unreadable icon image could not be used, instead of asking for one smaller than 50 MB.

## [0.1.0] - 2026-09-18

### Fixed

- Focus inactive windows on the first content click before allowing page links and controls to respond, without affecting background agent input.
- Load inspection, pointer and WebMCP scripts from the signed app's resource bundle so packaged Browser builds work without access to the build directory.

### Changed

- Support isolated build directories and remove development framework search paths from packaged debug builds.
- Preserve a tab's page size while it is in the background, avoiding unnecessary layout changes when switching tabs.
- Include custom browser icons in the companion catalogue so Noodle displays the same avatar when assigning browsers to bots.
- Make the entire tab clickable, including its icon and padding, with a separate close-button target.
- Place browser settings before the view controls in the native toolbar, matching Computer.
- Keep History and Bookmarks headers and search fields aligned when switching views.
- Center the address field between toolbar controls and use Computer’s shared content clipping and insets with a directly mounted native web view.
- Replace the icon popover with the suite’s full icon dialog, including file, Photos, Image Playground, colour and symbol controls; persist custom icon images per browser.

- Simplify browser creation to name, icon and per-browser background, prefill an available name, remove the duplicate empty-library creation button and engine label, and point Help to the main project.
- Use the suite’s background picker for each browser, including presets, imported images and videos, Photos and Image Playground; persist private background copies instead of sharing a global preference.

- Replace the card grid and separate browser windows with Noodle Computer’s single-window sidebar structure, circular icons, native unified toolbar, shared wallpapers, profile editor and browser/history/bookmark/download views.
- Add the suite’s native menus and General/Update settings, reusing its settings layout and pinned Sparkle updater with a dedicated signed Browser feed.
- Match Computer’s macOS 26 appearance baseline and shared transparent window host so wallpaper extends beneath the native sidebar and toolbar; size Settings to its content and remove the sidebar mute indicator.
- Align selected-tab corners concentrically with the browser content panel.

### Added

- Add built-in WebMCP compatibility for JavaScript tools and annotated forms, with CLI discovery/invocation, shared `eval` access, document-scoped tool IDs, validation, cancellation and background human handoffs.
- Ship a signed, notarized DMG alongside the ZIP, with large app and Applications icons and a drag-to-install layout.

- Add a visible per-tab agent pointer with native hover, primary clicks and double clicks, included in screenshots and page cards while leaving the desktop cursor and application focus alone.
- Use the suite's shared version-driven release pipeline, including signing, notarization, signed updates, an independent download channel and verified-artifact recovery.
- Add independent Show in Dock and Show in Menu Bar settings, with a menu for opening the library and saved browsers using the app’s symbol. Dock visibility defaults to on and menu bar visibility to off.
- Add browser page reference files and the agent `present` command, with a saved screenshot in Noodle and opening in the original profile and tab when available.
- Add a standalone symbol SVG and automatically compose the full icon SVG, PNG sizes and packaged macOS icon on every build.
- Register Runbar’s Build & Launch Dev entry for Browser, with a guarded development launcher matching Computer and Applet.
- Persist searchable per-browser history and bookmarks; let assigned agents inspect both and create, edit or delete bookmarks. Add native history/bookmark controls and human history clearing.
- Package both isolated Dev and normal Browser apps with `scripts/build-browser.sh --both`.

- Create named persistent browsers, sign in once, and assign the same live profiles to bots in Noodle.
- Navigate tabs, inspect pages and frames, run JavaScript, click, fill, send keys, scroll, answer dialogs, and capture screenshots without moving the system pointer or activating a window.
- Upload workspace files and retrieve completed downloads through the Noodle broker, with separate file storage for each browser.
- Keep tabs, website storage, download records and mute preferences across app restarts. Pause agent control during human use.
- Add the Browser app icon, native library and browsing windows, sandboxed signing, and separate development and production identities.

