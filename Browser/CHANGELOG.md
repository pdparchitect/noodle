# Changelog

## [Unreleased]

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

