# Changelog

## [Unreleased]

## [0.23.0] - 2026-10-03

### Added

- A noodlet opened from a Noodle conversation can be annotated where it is: press Noodle's Annotate Region shortcut in its window to mark a region, or its Add Annotation shortcut to quote the selected text, then add a comment, and it goes into that conversation's message. Needs the matching Noodle.

### Removed

- The `noodlet` command. Bots use Noodle Applet through the applet tool in Noodle and Noodle Hub, and Applet accepts requests only from those apps.

## [0.22.0] - 2026-10-02

### Added

- Noodlets can save and open files the standard web way: a download link, including one to a file the page makes itself, asks where to save it, and a file field opens the file picker. On iPhone, a download goes to the Files picker.
- Web links in a noodlet, including ones that open a new window, open in the browser instead of doing nothing.
- `noodle.storage.list()` names what a noodlet has stored, and `noodle.data.list(prefix)` lists its data files with their size and when they changed.

### Changed

- `noodle.data` keeps any kind of file, not only text: `write(path, data)` takes a string, Blob, ArrayBuffer or typed array, and `read(path)` returns a Blob. Each file can be up to 16 MiB. It replaces `readText` and `writeText`.

### Removed

- `noodle.files.openText()` and `saveText()`. A noodlet opens and saves the person's files with a standard file field and download link instead.

## [0.21.0] - 2026-10-01

### Changed

- Retire the clean-up of noodlet copies from before 0.12.0 and of Swift noodlet builds from before 0.19.0. Updates already pass through both releases.
- Any noodlet reaches the internet; `network` in noodlet.json is no longer needed. Reaching this Mac or devices on the local network, such as a TV, is the `local-network` permission, asked once like the camera and listed in Settings > Permissions. A noodlet that reached the local network with `network` declares `local-network` instead.

### Fixed

- A noodlet sent to a Noodle Hub device includes only the files inside it: a folder swapped for a link while it is read is refused, and its data and secrets are those of the noodlet that was checked.

## [0.20.0] - 2026-10-01

### Added

- Noodlets can run on the phones and Macs of people using a bot through Noodle Hub. Their data and secrets are kept by Noodle Applet on the Hub's Mac, the same wherever the noodlet runs.
- Optional manifest hints `layout` (desktop, phone or adaptive) and `runs` (device or hub) say how a noodlet is laid out and where it works best when opened from another device. A noodlet that declares a permission always runs on the device it is opened on.
- `noodle.features` lists what a noodlet's page can use where it runs, such as files or window.
- Optional manifest `display` (browser, standalone or fullscreen) says whether a noodlet is a web page or an app that fits its view, without page scrolling, zoom or text selection; `orientation` (any, portrait or landscape) holds a phone one way while it is open; and `backgroundColor` shows until the page paints.
- Optional manifest `theme` (system, light or dark) fixes the look a noodlet's page sees, wherever it runs; without it the page follows the device's appearance.

### Fixed

- Noodle Applet starts on a Mac account with a long user name, instead of failing because the connection path is too long. Update Noodle as well.
- A noodlet can lock the pointer, as a game that turns with the mouse does, instead of leaving the Mac's pointer free beside its own. Escape releases it.
- A game watched from another device no longer turns choppy after a minute or two, or stalls once the Mac's display sleeps.
- Recordings keep a noodlet's music when it was already playing before recording started, as a game's usually is.

## [0.19.0] - 2026-09-30

### Changed

- Noodlets are no longer limited to 20 MB or 512 files, and hidden files and folders such as `.git` are no longer counted as part of them. Opening a noodlet no longer reads all its files.

### Removed

- `noodlet convert`. To move a noodlet between Applet and Applet Dev, copy its folder under the other extension.
- Noodlets written in Swift, with `noodlet typecheck` and the Orbital playground example, which leaves your library unless you changed it. One you already have no longer opens; rewrite it in HTML. Applet no longer needs Xcode or the Command Line Tools, and frees the space it used to build and run them.

## [0.18.0] - 2026-09-30

### Changed

- Let a live viewer that fell behind pick up again from a small picture built on what it has shown, instead of a full new picture about 40 times larger. Update Noodle, Noodle for iPhone and Noodle Hub as well.

### Fixed

- Requests beyond the few Applet answers at once wait their turn instead of being dropped unanswered, which bots and Noodle saw as failures.

## [0.17.1] - 2026-09-29

### Fixed

- Recordings no longer freeze for about a tenth of a second every two seconds. Applet looked through every bot's folder for new noodlets on the thread that captures the video; it now looks elsewhere.

## [0.17.0] - 2026-09-29

### Changed

- Send sharper live video when a noodlet cannot be captured at full speed, using the whole rate the viewer's connection takes. It used to go at about a third of it.
- Stop live video from stuttering every two seconds on a slow connection: a key frame goes only to a viewer that needs one. Update Noodle and Noodle for iPhone as well, so their live views ask for one when they cannot go on.
- Record noodlets at twice the bit rate, so fast motion such as rain in a game stays sharp instead of turning blocky. Recordings are about twice as large, still capped at 12 Mbps.

### Fixed

- Recordings of HTML noodlets running in the background no longer come out choppy. A page nobody could see got about one frame a second, so the video showed the same picture for a second at a time; it now draws at full speed while recorded.

## [0.16.0] - 2026-09-29

### Added

- Games can list the keys they use in their manifest. People watching on iPhone or iPad then get a controller instead of the keyboard, and holding a button holds the key.

### Fixed

- Pressing Escape in an HTML noodlet no longer makes the Mac beep, on screen or while someone plays it from a phone.
- Playing a noodlet from a phone no longer affects the Mac. Its keys went to whichever window was active, so they changed the library's selection, opened the emoji picker and beeped; they now go only to the game.
- Swift noodlets played from a phone get held keys as they go down and come up, with the key codes a keyboard sends, take typing as keys when no text field is focused, and no longer make the Mac beep.
- Closing a game no longer leaves its sound playing until you quit Applet. The menu bar kept the closed noodlet running out of sight; a stopped noodlet's page now always ends.

## [0.15.0] - 2026-09-29

### Added

- A Running section in the sidebar lists every noodlet that is up, including ones running out of sight for your bots. Control-click one and choose Stop to end it.

### Fixed

- Closing a noodlet that someone was watching or using from another device now really unloads it. Its page stayed in memory, and viewers were left on a frozen picture instead of seeing the view end.
- A bot updating a noodlet you had closed no longer brings it back as a window with sound. It restarts out of sight and muted; only a noodlet still open on your screen is replaced in place.
- Playing an HTML noodlet with the keyboard no longer makes the Mac beep. Games that read the arrow keys beeped on every press.

## [0.14.0] - 2026-09-29

### Added

- A noodlet can draw its own window buttons. With `"titlebar": "none"` in its `noodlet.json` the native close, minimise and zoom buttons are hidden, and its own buttons call `noodle.window` in HTML or `NoodletContext.window` in Swift to close, minimise, zoom or go full screen.
- A noodlet that draws its own window buttons can choose its window's corners: `"cornerRadius": 0` in its `noodlet.json` makes them square, and a larger number rounds them by that much instead of the standard Mac shape.

### Fixed

- A noodlet watched from your iPhone while its window is closed on the Mac keeps running as if seen. Games, such as ones drawn on a canvas, showed only their background because they paused themselves as hidden.

## [0.13.0] - 2026-09-28

### Changed

- Hub is now the first category in the sidebar instead of a section of its own, and lists the people on Noodle Hub beneath it. Choose someone to see only the noodlets their bots made. Needs the latest Noodle Hub.
- The app icon uses Apple's system blue, the same flat blue as the other Noodle apps.

### Security

- A native noodlet reaches the network only when its `noodlet.json` sets `"network": true`, as a web noodlet already did, and then only internet addresses, not other programs on this Mac. Native noodlets that fetch without it stop connecting until the flag is added.
- A native noodlet reads the clipboard only when you opened it. One an agent started out of sight cannot.
- Native noodlets reach only the system services and graphics drivers their frameworks need, instead of all of them.

### Fixed

- Native noodlets can use the on-device Apple Intelligence model again. It reported that the model was not ready.
- Applet no longer crashes on launch while it deletes what a noodlet that is gone had saved, as it could right after updating.

## [0.12.0] - 2026-09-28

### Changed

- Watching the noodlet live from Noodle Hub runs at up to 60 frames a second instead of 30, costs this Mac less for each frame and, while the picture stays still, sends nothing and checks it only a few times a second, so the picture keeps up better.
- A native noodlet watched live hands over each frame about twice as fast, without making a picture file of it first, so what you click shows sooner. Its screenshots are quicker too.
- Noodlets your bots make, in Noodle or on Noodle Hub on this Mac, stay in the bot's own folder. Applet finds them there and runs them where they are, instead of keeping its own copy. The copies it kept before are deleted when Applet updates; what a noodlet saved, its permissions and its links move to the bot's own noodlet.
- Settings > Permissions and Storage show where each noodlet lives, so noodlets with the same name can be told apart.
- Noodlets made by Noodle Hub's bots are listed under Hub in the sidebar, not in All, Recent, the categories or the menu bar's recent list.
- Applet follows the system's light or dark appearance instead of always being dark.
- Move to Trash and Remove no longer end in an ellipsis, since they only ask to confirm.
- Check for Updates, in the app menu and Settings > Update, no longer ends in an ellipsis.
- Only you bring a noodlet to the front, by opening it. Agents working on noodlets can no longer show a window, from Noodle or the `noodlet` command.
- When an agent updates a noodlet you have open, the new version replaces the old one in the same spot, with no gap. It takes the keyboard only if you were using the noodlet.
- Buttons that only open System Settings or a web page no longer end in “…”; “…” is kept for commands that ask for something before they act.

### Security

- A bot on Noodle Hub reaches only its own noodlets and those shared with its conversations. Before, it could list and use every noodlet on the Hub's Mac, other people's included.

### Fixed

- Clicking a button in a native noodlet you are watching live from Noodle Hub now presses it. Before, buttons and other tappable parts ignored clicks while the noodlet's window was not on screen.

## [0.11.1] - 2026-09-27

### Fixed

- Lighten live video when Noodle Hub says the viewer's connection is slow, so the view keeps up instead of stuttering.
- Live video keeps a steady frame rate, and the app stays responsive while someone watches. Encoding each frame no longer holds up the app.
- A noodlet watched live from another device draws everything it shows, even when it was never opened on this Mac. Before, anything it drew frame by frame stayed blank until someone opened it here. It stays out of sight on this Mac while it is watched.

## [0.11.0] - 2026-09-26

### Added

- Let Noodle Hub run its bots' noodlets and show a running noodlet live to a person, taking their clicks, typing and scrolling.

### Changed

- A request from a newer Noodle or Noodle Hub that this version cannot read says to update Noodle Applet, instead of that the data could not be read.
- Stream live views to Noodle Hub as video, pushing each picture as soon as it is ready, at the size of the viewer's window, and skipping old pictures for a viewer that falls behind. While someone watches a noodlet, bots cannot use it until they close the view.

### Fixed

- Opening the app again brings the copy already running to the front instead of starting a second one on the same data, however it is started.

## [0.10.0] - 2026-09-25

### Added

- Move a noodlet to the Trash from the library's context menu. Its saved data, secrets and permissions are deleted with it.
- Browse noodlets by category. A noodlet can declare one category in `noodlet.json` (games, productivity, utilities, developer, data, creativity, media, writing, learning or lifestyle), and the library sidebar gains a collapsible Categories section listing only the categories that hold a visible noodlet.

### Changed

- Keep a fixed-size noodlet's shape on a TV. **Play On** used to stretch a noodlet made at a fixed size, such as a game, across the whole screen. It now keeps its own size, scaled up as far as it fits and centred on black, stays sharp and keeps keyboard focus. A resizable noodlet still fills the screen.

### Fixed

- Keep every card in a library row the same height. A long noodlet title now stays on one line and shows in full on hover, instead of wrapping and making its card taller than the rest.

## [0.9.0] - 2026-09-24

### Added

- Record a noodlet with its sound. `record` now adds what the noodlet plays to the MP4 as an AAC soundtrack, including while it runs muted in the background or headless, so the Mac stays quiet. HTML pages are heard through Web Audio and their own media elements. Swift noodlets play through the new `NoodletContext.audioEngine`, which also runs silently out of sight, where other audio APIs cannot start.
- Hide a noodlet from the library's context menu. Hidden noodlets move to a new Hidden tab and no longer appear in All, Recent, Pinned or the menu bar; Unhide brings them back with their pin.
- Show a noodlet's package in Finder from the File menu while its window is in front.
- Play a noodlet on a TV. **Play On** in the File menu and the library's context menu takes an HTML or Swift noodlet full screen on another display, including an Apple TV or AirPlay TV added as a separate display; **Add TV or Display…** opens Displays settings to add one, and **Bring Back to This Mac** returns the window as it was.

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
