# Noodle and Computer integration

Noodle discovers and starts the separately installed Computer app as needed.
The provider keeps running when its window closes; quitting Computer stops its
guests. Both apps must be signed by the same team.

## Requests and access

```text
Bot → Computer CLI → Noodle broker → Computer provider → Guest
```

The shared protocol lives in this package. Apps authenticate each other over a
private Unix socket in their scoped App Group. Compatibility depends on protocol
versions and capabilities, so app release numbers do not need to match.

Noodle owns bot assignments and checks them for every request. Each bot can start
an assigned computer and open, read, write, resize, or close its own terminal
sessions. It cannot stop/delete the computer or access another bot's terminal.
Files and services inside a shared computer are shared by design.

Removing an assignment closes that bot's terminals and live previews. Already
sent input cannot be undone and is never automatically retried. Assignment checks
are not hard isolation against a bot with autonomous host access.

## Present in chat

Run the assigned Computer CLI from the bot's workspace:

```sh
./.agents/skills/computer/computer present --terminal SESSION_ID --conversation CHAT_ID
./.agents/skills/computer/computer present --computer COMPUTER_ID --conversation CHAT_ID
```

The first selects an exact terminal. The second selects a web display; for a
shell-only computer it requires a single active terminal, otherwise specify one.
The broker also checks conversation membership.

Cards store a historical preview and a computer reference, without display
credentials. Opening fetches live access after checking assignment and compatibility.
Saved cards remain readable if Computer is unavailable, but cannot restore deleted
computers or expired sessions.

Computer cards use a Noodle-owned interactive panel because Quick Look cannot
accept terminal keyboard input. Closing the panel leaves the shell running and
does not tell the bot that a task is complete. The web view stays on the guest
origin, with host clipboard, file panels, and media capture disabled.

## Tests

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Computer/Bridge
zsh Computer/Bridge/test-signed-connection.sh
swift test --disable-sandbox --filter 'ComputerAccessTests|MessengerDocumentationTests'
```

For guest integration, launch the signed Computer executable with
`--noodle-background --provider-integration-test`. After `PROVIDER TEST READY`,
launch the signed Noodle executable with `--computer-integration-test`.
These use temporary libraries and test assignment, terminals, revocation, and cards.
The provider cleans up after completion or ten minutes.

Noodle's `--computer-picker-test` opens an isolated assignment UI fixture.
Computer's `--provider-snapshot-test`, alongside its provider integration flags,
checks native desktop capture. Snapshot and preview geometry checks are in
`Computer/Tests/PreviewSnapshotTests.swift` and `PreviewGeometryTests.swift`.

[Computer](../README.md) · [Architecture](../../docs/architecture.md)
