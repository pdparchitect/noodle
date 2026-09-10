# Noodle Computer changelog

## Unreleased

## [0.1.0] - 2026-09-10

- New Shell and Desktop computers use the public, digest-pinned Noodle images 0.1.0. Desktop includes a lighter wallpaper and terminal palette. Existing upstream-based computers remain recognised without replacing their disks.

- Real-desktop snapshot verification now requires an actual rendered preview and exercises forced browser letterboxing and stretching; an icon fallback no longer counts as success in this integration test.

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
