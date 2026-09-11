# Noodle Computer images

## Unreleased

### Changed

- Shorten the image build, customization, and publishing guide.

## [0.1.4] - 2026-09-10

- Replace the default desktop wallpaper with a widescreen, paper-textured landscape in cream, teal and orange.

- Use bold text in the terminal welcome banner with the terminal's default color, removing the cream and blue styling.
- Change the terminal welcome tagline to “Your own agentic workspace.”

## [0.1.3] - 2026-09-10

- Derive release tags automatically from Images/VERSION after all selected builds pass, publish the exact tested images, and verify public versioned/latest digests before releasing Computer.

- Round desktop window corners to match the top panel, keeping maximized and fullscreen windows flush with the screen edges.
- Publish `:latest` tags for both tested images after their versioned uploads, with serialized publication runs. New computers can receive image fixes independently of app releases.
- Populate the initially missing Desktop and Shell `:latest` tags with the published 0.1.2 images, fixing registry 404 errors during computer creation.

## [0.1.2] - 2026-09-10

- Interactive terminals in both images welcome users with the approved Noodle ASCII logo in cream and cobalt, including standalone shell mode and desktop Bash. Non-interactive commands stay quiet; plain terminals and `NO_COLOR` use uncoloured text, and `NOODLE_BANNER=0` disables the welcome.

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
