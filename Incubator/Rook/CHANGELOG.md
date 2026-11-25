# Changelog

## [Unreleased]

### Added

- Before Rook is first used, after its welcome, it explains the risks of running autonomous attacking agents and asks you to type “I understand the risks” to accept them; Quit is the only other way out. It asks once.
- A Mission has a Scope: one rule per line, such as `*.example.com`, `example.com`, `203.0.113.0/24` or an address, with `deny` in front of anything out of scope. Its agents are told the scope with the objective, again whenever it changes, and when they read the Mission. Only the champion sets it, and the audit log keeps each version.
- A Mission's Linux computers reach the network only through a gateway of its own, which lets through its scope, the services opened under Exceptions and package sources such as Kali's, and stops everything else. Every kind of scan crosses it as it would without one. What it stops goes in the Mission's audit log, once per address, as do addresses that a name in scope and a denied one share. A computer added to a Mission, or taken out, moves at once; one in no Mission uses the network as before. A Mission's gateway holds up to three running computers.
- Exceptions, under Scope in a Mission, open services beyond the scope, such as lookup sites. They are never targets, and the agents are told only that there are some.
- A Mission keeps its gateway's logs in its folder, and so in its export: `network.log` with every connection and probe its computers made, allowed or stopped, named after the lookup that found it, and `dns.log` with every lookup and its answers. Show Network Log and Show DNS Log, in a Mission's context menu, open each in a window that follows it as it grows.
- The Scope and Exceptions editors say under the text what a line may be.

## [0.7.0] - 2026-11-25

### Changed

- Markdown attachments open in a window of their own, laid out with headings, lists, tables and code; Preview and Source in its header switch between that and the text as written. Metal shaders open there too, playing or as their source. Both annotate as any other preview.

## [0.6.0] - 2026-11-25

### Changed

- A computer's terminal and files are slightly see-through, so Rook's window shows behind them.

### Fixed

- Settings › Storage is as wide as Rook's other settings instead of a narrow column.
- A computer that cannot be made, started or upgraded says why, as when the Mac's disk is full. Rook showed nothing, so an upgrade that failed looked as if it had done nothing.
- Computers offer Upgrade when a newer Rook image is published, as in Noodle Computer: the sidebar says Upgrade available, and Upgrade is in the computer’s context menu and Edit Computer. The upgrade shows its progress in a window of its own. Rook never checked, so computers kept the image they were made with.
- Rook’s Shell and Desktop computers are called rook-computer, and sudo in them no longer warns “unable to resolve host”.
- Upgrading a computer from the Ubuntu-based images to the Kali-based ones no longer breaks it, with programs such as nmap missing their libraries. Home folders and /workspace come across; programs you installed need installing again.
- Kali's nmap, and other network tools Kali installs with extra permissions, start instead of failing with “Operation not permitted”, even with sudo.

## [0.5.0] - 2026-11-24

### Added

- Computers: Rook runs Linux computers itself and reaches servers over SSH, with Noodle Computer's own views. Make them with New Computer in the main window, where they are listed under Computers as agents are and open on their terminal, files or desktop. Choose a Mission's computers in Edit Mission, beside its team; they show at the top of its conversation, and its agents use them, run commands and move files, only while it is open. One computer can serve several Missions. Settings › Storage shows what they take up and reclaims space, as in Noodle Computer. New Shell and Desktop computers start from Rook's own images, with Rook's welcome and a crimson desktop.
- Help › License opens Rook's licence.

### Changed

- Restricted agents are siloed: they reach the network only for their harness's own model services and sign-in, so a web page, a package download or any other address a tool asks for is refused. An agent given unrestricted access is not siloed.

## [0.4.0] - 2026-11-23

### Added

- Agents can ask for the tool catalogue with `messenger --list-tool-catalogue`, as in Noodle and Pion; Rook offers no tools yet, so the list is empty.

### Changed

- The send button is Noodle's: an outline arrow while there is nothing to send, and a white arrow on the accent colour once there is.
- In Settings › Tools, the line between two connections ends where their status ends, instead of running to the edge.
- Agent and group marks are drawn in two shades of Rook's red accent in place of white on grey: a deep disc with a light piece on a dark window, a pale disc with the accent's piece on a light one, so the sidebar carries the app's colour, each piece stays easy to tell apart and the marks do not read as buttons.
- The window carries a faint wash of Rook's red accent over both the Frosted and Solid backgrounds, in place of plain grey; View › Background › Tint turns it off for a plain window.
- The app icon's ivory rook is shaded gently, lit from crown to base, on its flat crimson tile, and the rook is drawn as Pion's pawn is, in parts on the pawn's body and base, on a crimson tile in place of the rose.
- Rook's accent is a crimson in place of the dusty rose, so its buttons, marks and window read as the red team.
- The Mission graph is frosted glass with Rook's crimson wash, whichever background the window uses, instead of solid grey.

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
