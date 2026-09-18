# Changelog

## [Unreleased]

### Added

- Add an optional description of up to 500 characters to each browser in its editor. Assigned bots see it alongside the name when choosing a browser, the sidebar search matches it, and page-preview cards leave it out.
- Open a new tab by double-clicking the empty space in the tab bar; double-clicking a tab still only selects it.

### Changed

- Move the Create button into the sidebar's toolbar beside the sidebar toggle, apart from Back and Forward.
- Move the Edit Browser button after the view picker, beside Mute and Pause Agents.
- Tighten the corner radius of the content panel and selected tab so each sits evenly inside the corner around it.
- Give History and Bookmarks a larger, rounder search bar, and replace the bookmark plus button with an Add button, and drop the ellipsis from History's Clear button.
- Open History and Bookmarks entries in a new tab instead of replacing the page in the current tab.

### Fixed

- Keep the Downloads title at the same height as the History and Bookmarks titles so it no longer shifts when switching views.

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

