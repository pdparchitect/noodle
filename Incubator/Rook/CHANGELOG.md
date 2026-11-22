# Changelog

## [Unreleased]

## [0.3.0] - 2026-11-22

### Added

- Local Models offers Qwen3.5 122B-A10B for Macs with 96 GB of memory or more, and Qwen3.8 27B Uncensored, with its refusals removed for security and incident response work, from 32 GB.
- A Mission's lead can bring in agents it already works with in another group or Mission, and take out those whose part is done, so a Mission an agent opens no longer stays with that agent alone. The Audit Log records each change in the lead's name. A group's lead can do the same in its group.

### Changed

- View › Sidebar offers As List and As Icons. Missions, agents, groups and optional tool connections use compact pictures in Noodle’s sidebar rows and icon grid.
- Local models and image generation run on a newer MLX, with its fixes to Qwen and Gemma tool calls and Qwen's reasoning across turns, and faster prompt reading for Qwen3.5, Qwen3.6 and Qwen3.8.

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
