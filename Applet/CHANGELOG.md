# Changelog

## [Unreleased]

### Fixed

- Reopen the library when the app is opened after a quiet agent launch.

- Support CSS `--noodle-app-region: drag` and `no-drag` regions without stealing interaction from controls.
- Keep hidden title bars draggable with a native drag region above HTML and Swift content.

### Changed

- Use the Noodle icon family, shorten the library filter to All, put Computer's animated search on the right, remove redundant package labels, and simplify the menu bar popup.
- Remember opened external packages once and prune deleted packages, pins, and recents.
- Make the bundled Focus timer a responsive floating translucent macOS utility, upgrading only untouched example files.

- Match Noodle Computer's native sidebar, toolbar search, tabbed General and Update settings, application menu, and repository Help. Remove the library's decorative headings and footer; move menu bar preferences into Settings and remove the manual folder-watching controls.

### Added

- Render `.noodlet` documents in Finder Quick Look: HTML content and captured or authored Swift previews.
- Support native HTTP(S) fetch without browser CORS, with binary bodies/responses, cancellation, bounded transfers, and per-noodlet network control.
- Configure standard, floating, or Quick Look-style preview windows, native translucent or transparent backgrounds, initial/minimum/maximum dimensions, resizing, and optional frame restoration in the manifest.

- Introduce Noodle Applet, a separate macOS companion with a visual library of folder-backed `.noodlet` documents, automatic discovery, pins, recents, and optional menu bar access.
- Run HTML creations in WebKit with persistent storage and user-selected text file access. Run native Swift views through the installed Apple toolchain in a separate process.
- Add an authenticated CLI for package validation, build diagnostics, single-instance sessions, inspection, interaction, JavaScript evaluation, PNG captures, silent MP4 recordings, and termination.
- Preserve logs and data across source updates; use a separate test data directory for headless runs. Include Focus, Colour Field, and Orbital Playground examples.
- Add Computer-compatible Sparkle updates and CI release preparation, signing, notarization, verification, publication, and recovery through a separate Applet update channel.
