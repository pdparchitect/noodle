# Rook computer images

## [Unreleased]

## [0.2.0] - 2026-11-24

### Changed

- Shell and Desktop are built on Kali instead of Alpine and Ubuntu, so every Kali package is one `sudo apt install` away. Nothing more is preinstalled, and Rook's desktop, welcome and account are unchanged.
- Desktop starts Chromium without a window, so agents can attach to it at once; opening Browser shows a window from the same running browser.
- The desktop wallpaper is Rook's symbol in a crimson glow on near-black, drawn at 4K from the app's own symbol.
- The terminal welcome shows “Autonomous AI red team.” beside Rook's drawing, under its name.

## [0.1.0] - 2026-11-24

### Added

- Shell and Desktop images for Rook's computers, built from Noodle Computer's with Rook's banner and a crimson desktop wallpaper, published as `rook-computer-shell-image` and `rook-computer-desktop-image`.
