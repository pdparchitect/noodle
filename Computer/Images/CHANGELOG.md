# Noodle Computer images

## Unreleased

- Anchor the remote desktop canvas to the top-left instead of auto-centering it, avoiding a dark top strip at odd viewport sizes.

- Restore the desktop's black terminal with its standard dark palette, use a black focused-window border, and round the top panel corners while retaining the cream/cobalt wallpaper.

## [0.1.1] - 2026-09-10

- Publish under explicit product names: `noodle-computer-shell-image` and `noodle-computer-desktop-image`, avoiding ambiguity with the main Noodle app.
- Supersedes the ambiguous initial package names, which are removed before the first app release; no compatibility aliases are maintained.

## [0.1.0] - 2026-09-10

- Initial ARM64 Shell and Desktop images, built from repository-owned Dockerfiles with pinned upstream bases.
- Desktop includes a lighter cream/cobalt wallpaper and a readable terminal palette.
- Builds validate both image contracts and actual desktop wallpaper rendering before publishing versioned GHCR images.
- Image versions are independent of app releases. Existing computer disks are never automatically replaced.
