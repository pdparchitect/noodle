# Changelog

## [Unreleased]

### Added

- Record a noodlet with its sound. `record` now adds what the noodlet plays to the MP4 as an AAC soundtrack, including while it runs muted in the background or headless, so the Mac stays quiet. HTML pages are heard through Web Audio and their own media elements. Swift noodlets play through the new `NoodletContext.audioEngine`, which also runs silently out of sight, where other audio APIs cannot start.

## [0.8.2] - 2026-09-24

### Fixed

- Keep every card in the library inside its own column. A noodlet whose preview image is wider than it is tall stretched its card past the grid, so it covered the card beside it.
- Keep a noodlet quiet while it is out of sight. A noodlet a bot runs in the background or headless no longer plays sound on the Mac: HTML pages are muted until they are shown and muted again when they are hidden, and a Swift noodlet started outside the foreground runs without audio output. A noodlet granted the microphone keeps its audio.
- Open a noodlet in the foreground when it is clicked, whatever the bot left running. A background page is shown and unmuted; a Swift noodlet or a headless test session, which cannot gain sound or normal data after it launched, is closed and started again in the foreground.

## [0.8.1] - 2026-09-22

### Fixed

- Record a noodlet at 30 fps, evenly. Capture used to pause a fixed interval after each frame, so the time the screenshot itself took came off the frame rate: recordings ran at about ten uneven frames a second and looked choppy. A noodlet that cannot be captured that fast now holds each frame for a whole number of frames instead of drifting.

## [0.8.0] - 2026-09-21

### Added

- Check for updates when Noodle's Settings > Companions asks: its Update action opens Applet and starts the check.

## [0.7.0] - 2026-09-21

### Changed

- Rename the Settings > Update button to Install Update… once a newer version is found. The app menu keeps Check for Updates….
- Keep development-only diagnostics out of the released app. Release packaging now verifies that none are present.

## [0.6.0] - 2026-09-20

### Security

- Confine native Swift noodlets to their own files. They compile and run under a deny-by-default sandbox that reaches only their package, data directory and a private home directory, so a noodlet can no longer read other noodlets, Applet's storage, its Keychain secrets or anything else on the Mac. A new `NoodletHost.xpc` service applies it, because App Sandbox refuses nested sandboxes.

### Added

- Add `NoodletContext.files.open()` and `files.save(_:suggestedName:)` for native noodlets. Applet shows the dialog and copies only the chosen file into or out of the noodlet's data directory. `NSOpenPanel` and `NSSavePanel` no longer work inside native noodlets.

- Let noodlets use the microphone, camera, speech recognition and screen recording. A noodlet declares `"permissions": ["microphone", "camera", "speech-recognition", "screen-capture"]` in its manifest; Applet asks once per noodlet before it starts, then macOS asks for Noodle Applet. Adds the audio input and camera sandbox entitlements. A new screen recording grant applies after Applet restarts.
- Give noodlets a place for API keys and tokens. `noodle.secrets` in HTML and `NoodletContext.secrets` in Swift keep values in Applet's Keychain, separately for each noodlet. Settings > Secrets lists their names and removes them.
- Show what each noodlet has saved, and remove it, in Settings > Storage.
- Let HTML noodlets that declare `screen-capture` share the screen with `getDisplayMedia`. macOS shows its own picker.
- Report each permission a noodlet declares as `granted`, `denied` or `not-requested` in `info`, `status` and `open`, and list and remove what each noodlet was allowed in Settings > Permissions.
- Add `noodlet typecheck --path FILE_OR_FOLDER` to check any Swift sources and return compiler diagnostics, without a noodlet manifest, import or session.
- Report why a failed session stopped in a new `failure` field on `status` and other session responses.

### Fixed

- Compile Swift noodlets that use `@State`, `@Observable`, `@Entry` and other macros. The toolchain's macro plugins are now found when Xcode is installed; Command Line Tools alone do not include SwiftUI's macros, and a failed build says so.
- Run Swift noodlets that use `.task`, `if #available` or other back-deployed APIs instead of exiting at startup with a missing `__isPlatformVersionAtLeast` symbol.
- Report the first line a Swift noodlet wrote to standard error when it exits during startup or fails later, instead of only an exit status.
- Stop reporting a capture warning from Applet's own runtime in every Swift noodlet's build log.
- Open noodlets from the library in Noodle Applet Dev instead of failing with "The caller belongs to a different Applet environment."

## [0.5.0] - 2026-09-19

### Added

- Show when a newer version is available in Settings > Update, and badge the Update tab on macOS 26 and later. The app asks its updater when Settings opens, without offering the update; versions you chose to skip are not announced.
- Choose a macOS system wallpaper as the background. Choose Background opens a System Wallpapers dialog showing thumbnails of the wallpapers already on this Mac, including dynamic ones, macOS's bundled video wallpapers and downloaded aerials, which play as animated backgrounds; clicking one chooses it. Wallpapers that System Settings has not downloaded are left out, and a Wallpaper Settings link opens System Settings to download more; the dialog refreshes on return. Reading downloaded wallpapers adds read-only sandbox exceptions for macOS's downloaded-wallpaper and aerials folders.

### Changed

- Move the Open Noodlet button into the sidebar's toolbar, after the sidebar toggle, on macOS 26 and later; it returns to the main toolbar while the sidebar is hidden. It now uses the suite's plus icon.
- Start Create Image from the still image being previewed, however it was chosen, instead of only from Photos and generated images.
- Explain that an iCloud photo may need downloading when Photos cannot provide the chosen background.

### Fixed

- Stay out of the Dock and app switcher when Show in Dock is off; opening a window or a request from Noodle no longer brings the Dock icon back.
- Build with the selected Xcode SDK recorded in the app, so builds made with Xcode 27 keep the current macOS appearance instead of falling back to the legacy one.

## [0.4.0] - 2026-09-18

### Fixed

- Require a focus click before interacting with inactive library and noodlet windows, sharing the same behavior for HTML and native Swift noodlets.

### Added

- Ship a signed, notarized DMG alongside the ZIP, with large app and Applications icons and a drag-to-install layout.

- Add Show in Dock alongside Show in Menu Bar, use the app’s symbol in the menu bar, and make Settings available from its menu. Dock visibility defaults to on and menu bar visibility to off.
- Add a standalone symbol SVG and automatically compose the full icon SVG, PNG sizes and packaged macOS icon on every build.

## [0.3.1] - 2026-09-17

### Fixed

- Shorten the library's top shadow and content fade to keep items near the toolbar clearer.

## [0.3.0] - 2026-09-17

### Changed

- Rename development apps, documents and links to Dev while keeping existing development packages and saved links readable.

### Added

- Add an isolated Noodle Applet Dev build with its own library, saved data, connection group, CLI and preview extension, using only `.noodlet-dev` documents and `noodlet-dev://` links.
- Add `noodlet convert --path SOURCE --output NEW_DOCUMENT` to copy documents explicitly between environments without overwriting existing files.

### Fixed

- Default development builds and Runbar launches to Applet Dev; reject cross-environment connections and links, and keep production file associations exclusive to production.
- Reduce idle library CPU usage by looking up known package paths before resolving bookmarks, caching library entry identifiers, and redrawing only when library details or previews change.

## [0.2.1] - 2026-09-16

### Fixed

- Remove development-only Metal toolchain framework search paths from packaged apps.
- Suppress settings scrollbar flashes during tab changes and dynamic window resizing on macOS 27, restoring indicators after the layout settles.

### Added

- Drop images, videos, and direct web media links onto the library background preview using the same importer and drop target as Noodle and Computer.

## [0.2.0] - 2026-09-14

### Fixed

- Correct the update documentation to use the existing Applet download channel.

- Preserve saved session identity, state and available mode metadata when inspection or other live operations target an archived session. Return `session-not-running` and keep status/log access available after Applet restarts.

- Resolve package links to active sessions before historical sessions, choose the newest stopped session consistently, and preserve session identity and mode in failed-operation responses. Allow explicit session targeting constrained to the authorized package.

### Added

- Report session mode, data scope, view availability, and HTML visibility/animation observations. Add opt-in headless HTML test clocks and bounded `step --frames` for synthetic offscreen RAF rendering without changing normal game visibility or user data.

### Changed

- Publish `Noodle-Applet-arm64.zip` and its checksum under stable filenames so download links follow the current release.

## [0.1.0] - 2026-09-13

### Fixed

- Keep noodlet CLI request publication inside its workspace mailbox, and permit broker calls when the bot sandbox denies process signaling; a denied liveness probe does not mean Noodle has stopped.

- Handle background preview and CLI launches through a dedicated URL, including sandboxed launches that discard command-line arguments. Keep the catalogue closed and existing creation windows visible; opening Applet directly still shows the library.

- Show the library when opening Noodle Applet directly; file and noodlet-link launches open only the requested creation without restoring the catalogue.

- Document that clicking a noodlet attachment opens its live Applet window; attaching alone keeps it closed.

- Reopen the library when the app is opened after a quiet agent launch.

- Support CSS `--noodle-app-region: drag` and `no-drag` regions without stealing interaction from controls.
- Keep hidden title bars draggable with a native drag region above HTML and Swift content.

### Changed

- Use the Noodle icon family, shorten the library filter to All, put Computer's animated search on the right, remove redundant package labels, and simplify the menu bar popup.
- Remember opened external packages once and prune deleted packages, pins, and recents.
- Make the bundled Focus timer a responsive floating translucent macOS utility, upgrading only untouched example files.

- Match Noodle Computer's native sidebar, toolbar search, tabbed General and Update settings, application menu, and repository Help. Remove the library's decorative headings and footer; move menu bar preferences into Settings and remove the manual folder-watching controls.

### Added

- Customize the library’s single background from Settings → General, with the same presets, images, Photos, generated images, and animated wallpapers as Noodle and Noodle Computer.
- Fade library cards beneath the toolbar over the same softly shaded wallpaper used in Noodle conversations, leaving sidebar content untouched.

- Register persistent noodlet IDs, handle `noodlet://UUID` links, and expose `info` for resolving a creation without running it. Keep IDs across source updates and tracked moves; give independent copies their own IDs.
- Add Open Library to the File menu.

- Render `.noodlet` documents in Finder Quick Look: HTML content and captured or authored Swift previews.
- Support native HTTP(S) fetch without browser CORS, with binary bodies/responses, cancellation, bounded transfers, and per-noodlet network control.
- Configure standard, floating, or Quick Look-style preview windows, native translucent or transparent backgrounds, initial/minimum/maximum dimensions, resizing, and optional frame restoration in the manifest.

- Introduce Noodle Applet, a separate macOS companion with a visual library of folder-backed `.noodlet` documents, automatic discovery, pins, recents, and optional menu bar access.
- Run HTML creations in WebKit with persistent storage and user-selected text file access. Run native Swift views through the installed Apple toolchain in a separate process.
- Add an authenticated CLI for package validation, build diagnostics, single-instance sessions, inspection, interaction, JavaScript evaluation, PNG captures, silent MP4 recordings, and termination.
- Preserve logs and data across source updates; use a separate test data directory for headless runs. Include Focus, Colour Field, and Orbital Playground examples.
- Add Computer-compatible Sparkle updates and CI release preparation, signing, notarization, verification, publication, and recovery through a separate Applet update channel.
