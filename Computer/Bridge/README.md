# Noodle ↔ Computer integration

Computer is a separately installed provider, not an embedded VM runtime inside
Noodle. macOS application discovery locates `com.pdparchitect.noodle.computer`.
Noodle quietly launches it with `--noodle-background` on initial discovery or an
on-demand request. SwiftUI suppresses the library window on background launch;
the app delegate owns the library/provider independently of any view. Closing
the library window does not stop it. Quitting Computer stops its guests; a later
CLI request can relaunch the provider and `start` an assigned computer.

This is the first versioned provider integration, not a general third-party
plugin loader. Other providers can adopt a future discovery catalogue without
putting their runtimes in Noodle. Interactive card rendering is intentionally
integrated into Noodle's existing attachment UI.

The bot editor's Computers tab uses the group-member layout: assigned computer
avatars with remove controls, plus a searchable Add Computers popover. Empty
catalogues offer to open Noodle Computer to create one. This is an explicit,
foreground app open; discovery stays quiet. Returning to Noodle refreshes the
catalogue without saving or changing assignments until the bot editor is saved.

## Boundaries

- Private Unix socket in `TEAM.com.pdparchitect.noodle.computers`, mode 0600.
  No TCP listener, shared library directory or globally accessible bearer token.
- Each connection authenticates the kernel peer audit token against the expected
  app identifier and signing team. Dynamic code validation avoids sandbox access
  to another application's on-disk executable. Accepted sockets use bounded,
  blocking worker I/O; only the listener is nonblocking.
- Noodle owns many-to-many assignments. Every CLI request checks agent identity,
  assignment and, for presentation, conversation membership. Mutation results
  recheck revocation. Removing an assignment closes that agent's provider PTYs.
- Each bot has a separate private workspace request channel. The CLI has no
  provider App Group grant; it cannot claim another agent identity in JSON.
  Full-access agents retain their explicitly granted host access; this protocol
  is not a security sandbox against a malicious full-access host process.
- One agent can start its assigned computer, and manipulate its own PTYs. It
  cannot stop/delete/reassign a computer or read another agent's PTY. Guest files
  and services are deliberately shared. No host clipboard or directory is shared.
- Replay is bounded to 256 KiB per terminal, with independent reader offsets.
  Exited terminals remain readable briefly and a new terminal can be opened.
  Closing a preview does not close the shell. Uncertain input is never retried.

## Interactive attachments

Discovery advertises a supported protocol range and named capabilities. Noodle
checks them before each live action, including after a provider restart, and
reports which app needs updating. Release numbers need not match. Legacy
providers without this handshake fail closed with an Update Noodle Computer
message; future capabilities are ignored when the required subset is supported.
Compatibility errors appear in assignment settings, live previews and CLI errors.
Historical conversation cards do not require a running or compatible provider.

Display snapshots wait up to eight seconds for document/assets, the built-in
desktop's connection and canvas, and a settled layout. Nearly uniform frames,
busy pages, failed navigation and stalled WebKit callbacks produce no snapshot;
the saved card then uses the normal computer-icon fallback. This is best-effort
visual readiness, not a guarantee that an arbitrary web app has completed its
work. Existing historical cards are not rewritten.
Snapshots preserve up to 1440 pixels on their longest edge, prefer lossless PNG,
and fall back to high-quality JPEG and smaller dimensions to stay within 512 KB.
Display cards use a larger, proportionate preview; terminal text cards are unchanged.
Check delayed pages, canvases, blank/busy fallback and cancellation without a guest:
`swiftc Computer/Sources/NoodleComputer/ComputerPreviewSnapshot.swift Computer/Tests/PreviewSnapshotTests.swift -o /tmp/noodle-preview-snapshot-tests && /tmp/noodle-preview-snapshot-tests`.
The signed Computer app also accepts `--noodle-background --provider-integration-test
--provider-snapshot-test` to create a temporary desktop, capture it without a
window, and clean up the guest. It never opens the user's computer library.

The conversation owns a typed `.noodlecomputer` reference, appearance and bounded
historical preview. No guest URL, password, certificate or access token is stored
in the card. Cards reuse normal attachment selection, click and Space entry.

An isolated Quick Look extension proof (`../Prototypes/QuickLook`) showed that
Quick Look rejects terminal first-responder ownership and uses Space to dismiss.
The user approved a Noodle-owned interactive panel for Computer cards instead.
Ordinary attachments still use Quick Look. The live panel returns focus when
closed; focused terminal keys, including Space, go to the guest. There is no
Done/continue button or automatic completion event.

Computer previews use a native behind-window visual-effect frame, compact
draggable header, close control and the same rounded inset for terminal and web
content. This matches Quick Look's visual treatment without using its keyboard-
restricted host. Native material respects Reduce Transparency; the terminal
remains opaque for readable text. No preview permissions change.
The last size and position are saved in Noodle's preferences across closing and
relaunch, shared by terminal and web previews. Restore constrains the frame to a
connected screen's usable area, including after a monitor is unplugged.

Window geometry can be checked without a running guest:
`swiftc Sources/Noodle/ComputerPreviewGeometry.swift Computer/Tests/PreviewGeometryTests.swift -o /tmp/noodle-preview-geometry-tests && /tmp/noodle-preview-geometry-tests`.
The test uses a private preferences suite and checks AppKit save/reopen plus
placement on single, multiple and disconnected-monitor configurations.

`present --terminal SESSION_ID --conversation CHAT_ID` selects that exact shell
and infers its computer. The broker resolves only the authenticated agent's own
session, then checks assignment before fetching output or creating an attachment.
`present --computer COMPUTER_ID --conversation CHAT_ID` selects its web display
without creating or requiring a PTY. On shell-only computers it selects the agent's
sole active terminal; zero sessions requires opening one and multiple sessions
requires an explicit `--terminal`. `--view` remains a compatibility override.
Web cards omit terminalID; existing cards with terminalID remain readable.
The saved appearance/snapshot remains readable if the app or computer is removed;
only live access fails. Reinstalling does not recreate a deleted computer/session.
The live browser obtains credentials only through a
broker-only display request, uses an ephemeral WebKit store and pins the built-in
desktop certificate. Navigation stays on the guest origin. Host clipboard, media
capture and file panels are disabled. Authorization is periodically rechecked;
revocation closes the live web surface. No automatic user-completion inference
is invented: an agent must observe the actual expected state or await a reply.

## Build and tests

Both apps need an Apple Development or Developer ID identity from the same team.
`scripts/build-app.sh` includes and signs `Contents/Helpers/computer`; only the
main app gets the Computer group, not Agent Host, the CLI, or the share extension.
`scripts/build-computer.sh` adds that group to its four runtime grants (sandbox,
virtualization, outbound networking and user-selected read-only imports), plus
the approved two-service Sparkle Mach lookup entitlement. Computer's signed
installer boundary and independent feed are described in [Releasing](../RELEASING.md).
Existing Noodle Agent Host and updater exceptions are unchanged.

Run:

```sh
swift test --disable-sandbox --package-path Computer/Bridge
zsh Computer/Bridge/test-signed-connection.sh
swift test --disable-sandbox --filter 'ComputerAccessTests|MessengerDocumentationTests'
```

The signed transport proof uses temporary test bundles and a separate test App
Group. It checks repeated authenticated round trips and rejects an unrecognized
signed identity. It never contacts the production provider.

For real guest integration, launch the signed Computer executable with
`--noodle-background --provider-integration-test`, wait for `PROVIDER TEST READY`,
then the signed Noodle executable with `--computer-integration-test`. These modes
use isolated temporary libraries, agents and conversations and `t.sock`, never
the user's normal provider endpoint. Computer auto-stops/removes its fixture
after ten minutes or the broker fixture's completion signal. Noodle tests assignment, start, CLI/PTYS, file sharing,
revocation, conversation membership, attachment creation and shell replacement.
Its card window allows a manual keyboard check before cleanup.

`--computer-picker-test` opens an isolated UI fixture with populated and empty
catalogues to check add, search, remove and the create prompt without changing
real assignments. Close its window to remove the fixture.

Not implemented here: remote-host discovery, a third-party plugin installer,
host/guest file transfer, or desktop mouse/keyboard automation APIs for agents.
Agents can operate installed guest tools through their terminals.
