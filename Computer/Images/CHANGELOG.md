# Noodle Computer images

## Unreleased

## [0.1.1] - 2026-09-10

- Publish under explicit product names: `noodle-computer-shell-image` and `noodle-computer-desktop-image`, avoiding ambiguity with the main Noodle app.
- The original 0.1.0 packages remain historical artifacts; app releases use the new names.

## [0.1.0] - 2026-09-10

- Initial ARM64 Shell and Desktop images, built from repository-owned Dockerfiles with pinned upstream bases.
- Desktop includes a lighter cream/cobalt wallpaper and a readable terminal palette.
- Builds validate both image contracts and actual desktop wallpaper rendering before publishing versioned GHCR images.
- Image versions are independent of app releases. Existing computer disks are never automatically replaced.
