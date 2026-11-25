# Rook computer images

## [Unreleased]

### Changed

- apt fetches Kali's packages from kali.download, Kali's own CDN, rather than a mirror near the computer chosen by http.kali.org, so installing works behind a Mission's gateway.

## [0.2.3] - 2026-11-25

### Fixed

- Desktop no longer leaves `~/.local` owned by root, which stopped tools such as nuclei from installing into it; computers that have it are repaired the next time they start.

## [0.2.2] - 2026-11-24

### Fixed

- Dragging a Desktop window no longer blanks what it shows until you click it.

## [0.2.1] - 2026-11-24

### Changed

- The terminal welcome draws Rook slimmer and taller, with a stepped base.

### Fixed

- Desktop's browser starts after the computer is renamed, instead of reporting its profile in use by another computer.

## [0.2.0] - 2026-11-24

### Changed

- Shell and Desktop are built on Kali instead of Alpine and Ubuntu, so every Kali package is one `sudo apt install` away. Nothing more is preinstalled, and Rook's desktop, welcome and account are unchanged.
- Desktop starts Chromium without a window, so agents can attach to it at once; opening Browser shows a window from the same running browser.
- The desktop wallpaper is Rook's symbol in a crimson glow on near-black, drawn at 4K from the app's own symbol.
- The terminal welcome shows “Autonomous AI red team.” beside Rook's drawing, under its name.

## [0.1.0] - 2026-11-24

### Added

- Shell and Desktop images for Rook's computers, built from Noodle Computer's with Rook's banner and a crimson desktop wallpaper, published as `rook-computer-shell-image` and `rook-computer-desktop-image`.
