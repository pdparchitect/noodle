# Changelog

## [Unreleased]

## [0.2.0] - 2026-11-21

### Changed

- Unrestricted access is off until turned on with `defaults write com.pdparchitect.rook AllowUnrestrictedAccess -bool true`; until then Settings › Bots hides it, and agents that had it run restricted, keeping it for when it is turned on.

### Fixed

- A link's card under your own message lines up with the right edge of the message, not partway in.
- A tool that works again wakes the agents it is assigned to and tells them, so one waiting on it retries and carries on; nothing told them before. That is when it is signed in again after failing or being signed out, and when a failed tool comes back by itself: a call that works shows it, and every five minutes a failed tool is checked. Its tools are listed in their skills before they are told, even if it never listed them before; its failure mark clears, and its activity says it is working again and who was told.

## [0.1.0] - 2026-11-20

### Added

- Explore mission attack graphs with selectable, draggable nodes, highlighted connections and spaced directional layouts. The translucent frosted panel resizes with even 48-point margins, closes with Escape, and supports scrolling, fit-to-view and pinch or button zoom with sharp rendering.
- Pan mission graphs by holding the middle mouse button, with a four-way drag cursor until release. Mouse-wheel scrolling zooms the graph while trackpad scrolling stays unchanged. The graph opens as a native modal sheet, dimming the parent window and blocking its toolbar until dismissed.
- A scenario step can open a Mission's attack graph, so `exposed-git` photographs it.
- The README shows Rook at work, in screenshots retaken over its banner artwork with `scripts/readme-shots.sh`.

### Fixed

- Release verification recognises Rook's own update channel instead of expecting Noodle's.
