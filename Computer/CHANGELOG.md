# Noodle Computer changelog

## Unreleased

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
