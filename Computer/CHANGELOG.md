# Noodle Computer changelog

## [Unreleased]

### Added

- Add independent Show in Dock and Show in Menu Bar settings, with a menu for opening the library and saved computers using the app’s symbol. Dock visibility defaults to on and menu bar visibility to off.
- Add a standalone symbol SVG and automatically compose the full icon SVG, PNG sizes and packaged macOS icon on every build.

## [0.8.1] - 2026-09-17

### Added

- Open multiple Local Mac windows individually or use Open All Windows to pop out visible root windows with their sheets and dialogs. New windows tile automatically on each monitor; Open All Windows also restores and re-tiles existing previews. Opened windows remain available across Computer views, and input activates the selected guest window.

### Fixed

- Preserve individual pop-out sizes when opening all Local Mac windows; arrange them without enlarging them to fill the screen, shrinking only when needed to fit.
- Recover Focus Window and its input after a Local Mac restart when macOS omits the frontmost app, using verified accessibility focus within the assigned account.
- Use the same compact toolbar shadow as Noodle and Applet, keeping desktop and terminal content clear.
- Focus the existing library window when opening computer attachments, selecting their computer without presenting the window again.
- Include the desktop helper's Apple Events entitlement and usage description so Local Mac commands can request approval to automate apps.
- Close Focus Window automatically when its source popup or window closes, and ignore late replies from the ended preview.
- Keep Local Mac Setup out of the Dock and app switcher, including during background registration checks.
- Recover idle Local Mac helpers after signed app replacement without depending on an authenticated request reaching the old executable.
- Add Repair Local Mac in Setup to reload a stuck registered helper, wait for macOS registration to settle, and retain accounts and files.
- Quit Computer Dev before installing a replacement so the running app cannot keep serving requests from a removed executable.

## [0.8.0] - 2026-09-17

### Changed

- Place the optional Focus Window action after the Desktop, Terminal and Files controls.
- Rename the development app and setup helper to Dev, preserve existing accounts and registered helper paths, and separate development and test document types from production.

### Added

- Pop the focused Local Mac window into an interactive, resizable preview from the toolbar, with a sharper capture that includes child windows while retaining the normal desktop view.

### Fixed

- Keep Focus Window available when optional accessibility ancestry is unavailable or its root cannot be matched to a captured window.
- Disable Focus Window during shutdown and reject queued preview requests once stopping begins.
- Focus the owning root window when a sheet or popup is selected, include its dialogs, and keep the preview anchored to the document as dialogs open and close.
- Initialize new Dev accounts with a shell banner hook pointing to their own Dev desktop helper instead of the production filename.
- Avoid a dangling background-color pointer when starting Focus Window capture, which could crash the desktop helper.
- Allow Local Mac deletion after a failed start or while waiting for desktop permissions; stop the owned background session before removing its account.
- Reveal a verified standalone desktop helper for macOS permission approval, label it correctly in Finder, and keep missing permissions from starting a capture request that can time out.
- Stop recreating retired Local app aliases during subsequent Dev installations.
- Recover the Local Mac helper after an app update even when macOS rejects the old executable's reply, and offer operation-specific recovery when deletion cannot reach the helper.
- Check Local Mac home access before deleting files, explain macOS privacy denials with an action to open Full Disk Access, and retain the account when cleanup cannot finish.
- Install development builds in /Applications so separate Local Mac accounts can launch their helper, and report inaccessible app locations before account login.
- Distinguish Noodle Computer Setup and Noodle Computer Dev Setup in macOS background items and approval messages.
- Detect Local Mac registration and approval before startup, show first-time setup as an expected state, and refresh it after returning from System Settings instead of reporting a broken computer.
- Remove the empty library's container-only creation button; use the toolbar's plus menu for all computer types.
- Isolate Noodle Computer Dev's library, connection group, Local Mac services and account credentials from the installed release, and pair it only with Noodle Dev.
- Remove SwiftPM's generated package-framework search path from packaged apps.

## [0.7.2] - 2026-09-16

### Fixed

- Reconnect the terminal and file browser when restarting a failed Local Mac connection, and prevent an unfinished terminal startup from restoring the old connection.
- Remove development-only Metal toolchain framework search paths from packaged apps.
- Suppress settings scrollbar flashes during tab changes and dynamic window resizing on macOS 27, restoring indicators after the layout settles.

### Added

- Show the images' Noodle Computer welcome banner in Local Mac interactive terminals, including Terminal.app inside the managed desktop, while preserving existing shell settings.
- Drop images, videos, and direct web media links onto the background preview using the same importer and drop target as Noodle and Applet.

## [0.7.1] - 2026-09-15

### Changed

- Use a plus icon for the toolbar's Create menu.

### Fixed

- Keep other Local Mac folders readable while one folder waits for macOS consent, and prevent repeated folder reads from filling the file-operation queue.
- Detect an unlaunchable Local Mac account helper promptly and offer registration repair after app signing changes, preserving accounts and files.
- Explain how to restore the existing Local Mac credential's Keychain access when a signing change prevents background login.
- Keep Local Mac permission recovery in computer settings, show only the current desktop issue, and clear stale input errors when control is restored.

## [0.7.0] - 2026-09-14

### Changed

- Keep container and Local Mac creation separate; name the standard image flow “New Container” and expose Local Mac in both creation menus.
- Use the shared name, icon, background and automatic-start conventions for Local Mac creation; show account resources in its settings without container or display-resolution assumptions.
- Start repository-owned desktop images through their authenticated startup contract and honor image appearance/session defaults, while retaining startup support for existing saved images.

### Fixed

- Repair damaged Local Mac desktop helpers, publish updates atomically with rollback, and reconnect to updated lifecycle services without resetting their approval or retained accounts.
- Report Local Mac folder permission denials accurately, include account folder access descriptions, and keep desktop capture and input responsive while file operations wait for macOS consent.
- Clear Local Mac capture coordinates when recording fails so input cannot use a stopped display.
- Handle Control-C explicitly in the focused terminal and add an Interrupt Command context-menu action.
- Treat an intentional Local Mac stop as normal shutdown, ignore stale connection callbacks, and preserve connection state when a status refresh fails.
- Verify Local Mac helper protocol compatibility before capture and keep display separation checks active during status updates and frame delivery.
- Start Local Mac capture independently of resolution changes; remove unused display/window-targeting experiments, the obsolete Finder command and service re-registration maintenance path.
- Capture the verified Local Mac display as a whole so sharing controls no longer cover each window’s traffic-light buttons.
- Resolve the file browser's Home shortcut through the running system and account, including non-root Linux image users, instead of assuming `/root`.
- Use the normal stopped-computer screen and toolbar Start for Local Mac; show the enable action only when startup finds the account service unavailable.
- Remove the Open Finder recovery button and its banner from the Local Mac desktop.
- Deliver Local Mac pointer and keyboard sequences through the verified background session, preserve drag releases under input load, and capture app shortcuts while the native desktop has focus.
- Keep trailing decimal zeroes and use equal-width digits in image download progress so changing byte counts and speeds stay visually steady.
- Local Mac desktop capture now checks the desktop helper's own permissions when launched by the account service.
- Map Local Mac pointer coordinates correctly through the preview’s aspect-fit padding.
- Stop reading scroll-wheel properties from ordinary mouse events, which caused AppKit to discard clicks and movement before they reached the Local Mac account.
- Remove persistent display-resolution diagnostic banners from the Local Mac viewer; keep those details in logs.
- Disable the managed account's idle screen saver at startup so unattended Local Mac desktops do not automatically lock after inactivity.
- Use a short current-folder prompt in Local Mac shells, without the generated account or host name; preserve existing shell customizations.
- Use the shared native file browser for Local Mac, including navigation, icon/list views, Quick Look, folder transfers, drag-and-drop, renaming and duplication. File operations remain confined to the managed account's home, with atomic uploads and cancellation cleanup.

### Added

- Experimental Local Mac computers backed by retained standard accounts, with a 1280 × 800 native viewer, account terminals and file transfers, and saved `.noodlecomputer` previews. Account setup uses an explicitly enabled lifecycle helper; stopping retains the account and its permissions.
- Prepare a per-account setup-skip marker and onboarding history before background login so Local Mac opens its desktop without clicking through Setup Assistant.

### Known limitations

- Local Mac remains experimental and depends on private macOS APIs investigated on macOS 26.6.2. Live validation of the final signed app's permissions, agent access, update/reconnect, sleep/wake, and reboot behavior remains outstanding; see [Local Mac validation](https://github.com/pdparchitect/noodle/blob/computer-v0.7.0/Computer/LocalMac/README.md#validation).

## [0.6.0] - 2026-09-14

### Fixed

- Repair terminal prompt release checks after moving shell configuration, covering both root and non-root prompts.

- Explain blocked Local Network access with Open Settings and Try Again actions, include a reason in macOS's permission prompt, and return the actual startup failure to the CLI. Failed computers can be started again after recovery.

- Preserve the Quick Look extension's root view while loading saved computer previews and redraw after native resizing, keeping its view connection and displayed content intact.

### Changed

- Remove unused command and preview-cache helpers, and exercise normal cache expiration in the file-browser regression fixture.

- Own `.noodlecomputer` reference files and sandboxed Quick Look previews and thumbnails. Opening a file selects and starts its computer in the main window, without an extra preview window or agent assignment checks. Saved previews work offline and show only their desktop or terminal content, without extra titles or footers.

- Honor the image's configured user and environment in native terminals, agent terminals, commands, and file transfers, allowing the Shell and Desktop images to use a non-root account with sudo.

- Support Command-K to clear terminal output while preserving current input, and start the guest’s configured interactive shell so history and line editing work on images that provide Bash or Zsh.
- Explain invalid container image names with copyable corrections before downloading, and give recovery steps for missing images, denied access, download limits, and registry failures.
- Publish `Noodle-Computer-arm64.zip` and its checksum under stable filenames so download links follow the current release.

## [0.5.0] - 2026-09-13

### Changed

- Simplify the stopped-computer message in Noodle's live display, removing the CLI command and computer ID.

### Added

- Import folders from Finder or the file picker, preserving nested and empty folders, with byte/item progress and cancellation. Completed items are kept when cancelled; existing items are never overwritten.
- Export folders to Finder or a chosen location with progress and cancellation, discarding incomplete exports. Drop imports directly onto subfolders, highlight folder targets, and use native copy/move cursor feedback consistently in icon and list views.

## [0.4.0] - 2026-09-12

### Added

- Support native file upload/download requests from Noodle agents using the existing guest file helper, with bounded streaming, private staging, and capability discovery.

### Changed

- Simplify the Computer setup, file, integration, and release guides; separate build instructions from the README.

## [0.3.0] - 2026-09-11

- Install the Go compiler in release preparation so the guest file helper is included in published builds.

- Add a screenshot gallery to the Computer README.

- Use consistent native toolbar styling and sizing for file navigation, the view selector, actions and search, keep the collapsed search button round, and vertically center the search text and caret.

- Show file navigation, layout, actions and search in the main window toolbar only while Files is selected, with Back/Forward on the left, the remaining file controls on the right, and no folder-name label.

- Remove the transient folder-loading spinner so the Files toolbar stays still when navigating or refreshing.

- Place Start/Stop before one segmented toolbar control for Desktop, Terminal or Files, showing only available views and keeping the desktop connection and shell session alive. Use standard spacing between Edit and Start/Stop.

- Align file sizes with their rows and keep filenames on one line with ellipsis truncation.
- Keep Files uncluttered with a single compact navigation bar, an animated expanding search field, and file actions in menus. Match the terminal's background colour and opacity, add a gallery layout, and support Finder-style arrow keys, type-to-select, Command-Up/Down, history and rename shortcuts.

- Match Noodle's full background support through a shared importer and renderer: still images, multi-frame HEIC/HEIF, and muted looping MP4/M4V/MOV video, with the same limits, Photos and Image Playground choices, hidden-window pausing, and Reduce Motion behavior. Keep media in each computer's private library and preserve existing image backgrounds.

- Add a Finder-style Files view for running containers, with native folder/file icons, icon and list layouts, folder navigation, file imports/exports and Finder drag-and-drop, rename, duplicate, move, and empty-folder/file deletion. Preview supported images, PDFs and text with Quick Look, capped at 20 MB per file and a 100 MB expiring private cache.

- Crossfade window backgrounds when switching computers or applying a background, matching Noodle's timing and respecting Reduce Motion. Prepare images before fading and keep the empty library's default background opaque.

## [0.2.1] - 2026-09-11

- Run Computer, Noodle integration and shared-protocol release tests concurrently; image preparation starts without waiting for app compilation.

- Recover publication from already verified release artifacts when a workflow stops after tagging.

## [0.2.0] - 2026-09-10

- Publish Computer automatically from its VERSION file after all selected release checks and packaging succeed, with derived tags and verified images published first.

- Keep the networking requirement beside its toggle so switching computer types does not resize Advanced Options.

- Smoothly animate the create-computer dialog's size, Advanced Options expansion and collapse, and disclosure chevron, respecting Reduce Motion.

- Add Settings → Storage with Studio’s usage summary, cache preview, refresh and confirmed cleanup/restart flow. Remove unused image and installer caches while preserving computer disks, writable layers, recovery copies and startup files.

- Choose what to create with selectable computer cards showing each option's icon, name and description, replacing the Template dropdown.

- Simplify template and networking descriptions, remove redundant settings help, and load template names, types, images and resource settings from an extensible container registry instead of fixed presets.

- Explain image registry failures with the requested image and HTTP status, including missing image tags, instead of an opaque “RegistryClient error 0”.

- Store container images as read-only bases with persistent writable overlays. Update from the computer context menu or Edit Computer pulls the current image, preserves local changes, verifies startup and switches disks atomically. The new layout does not migrate older flat disks.

- Place Update above Start/Stop with a separator in the computer context menu, place Update beside Stop at the bottom of Edit Computer, and remove the ellipsis from Stop.

- Start newly created computers automatically, with an enabled-by-default toggle in Settings → General.

- Align the visible bottom edge of the WebKit and terminal panels with the sidebar by correcting the extra one-point bottom inset.

- Include the current application ZIP and checksum in the `computer-latest` release Assets, alongside the update feed, so manual downloads are easy to find.

- New Desktop and Shell computers fetch the current `:latest` image from GHCR, including refreshed network setup files, so image fixes no longer require an app release. Image selection is refreshed for each new computer.

## [0.1.2] - 2026-09-10

- Restore the missing Check for Updates menu command and add Settings → Update using Noodle's layout, with the installed version, automatic checks and opt-in automatic download/install. Automatic installation remains off by default.

## [0.1.1] - 2026-09-10

- New computers use the digest-pinned 0.1.2 images, with the Noodle terminal welcome, black desktop terminal and window borders, and rounded desktop panel. Existing computer disks and customisations are not replaced.

- Preserve Desktop and Shell recognition for computers created with previously released images when the default image digests advance; existing disks remain unchanged.

- Native and agent terminal sessions use the image's interactive shell startup hook, so new images can show the Noodle welcome without changing non-interactive command output.

- Remove automatic centering of the embedded desktop canvas to prevent a dark top strip at odd viewport sizes. Custom web applications are unaffected.

- Inset terminal and desktop clipping by one point to match the native sidebar's inner glass edge, keeping their shared layout bounds unchanged.

- An empty library or cleared computer selection now has an opaque default background instead of showing other windows through the content area.

## [0.1.0] - 2026-09-10

- New Shell and Desktop computers use the public, digest-pinned `noodle-computer-shell-image` and `noodle-computer-desktop-image` packages. Desktop includes a lighter wallpaper and terminal palette. No compatibility aliases for pre-release image names are retained.

- Real-desktop snapshot verification requires an actual rendered preview and exercises forced browser letterboxing and stretching against the captured native pixels, including light wallpapers; an icon fallback no longer counts as success in this integration test.

- Desktop snapshots capture the native remote framebuffer rather than the browser viewport, removing baked-in grey letterboxing and avoiding browser-scale distortion.

- Desktop thumbnails fill a consistent card area, anchored at the top-left and cropping overflow instead of fitting the entire desktop. Full live previews are unchanged.

- Sharper display attachment previews preserve up to 1440 pixels with lossless PNG when possible, use larger proportionate cards, and explain when a snapshot is unavailable. Detailed images remain within the existing attachment size limit.

- The personal terminal uses a portable working-directory prompt instead of displaying a literal `\w` in desktop images.

- Terminal and display previews offer Get Noodle Computer when the app is missing, using the same download flow as setup.

- Display cards wait briefly for a rendered page and use the computer-icon fallback instead of saving blank or loading previews.

- Runtime compatibility checks identify which app needs updating before using unsupported Computer capabilities.
- Noodle-inspired Computer icon with the shared cobalt and cream palette.

- Simplified presentation commands infer the computer from a terminal ID, and web previews no longer require a terminal. Ambiguous shell sessions require an explicit choice.

- Computer previews remember their last window size and position and stay within connected screens.

- Quick Look-style frosted preview frames with compact headers and rounded live terminal/web content.

- Standalone computers with Desktop, Shell and custom container images.
- Shared agent assignments, quiet discovery and interactive computer previews in Noodle.
- Independent signed releases and a download entry point from Noodle.
- Signed automatic update checks, with user-controlled installation.
