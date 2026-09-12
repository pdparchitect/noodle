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

## Transfer files

```sh
./.agents/skills/computer/computer upload --computer COMPUTER_ID --source wallpaper.png --destination /workspace/wallpaper.png
./.agents/skills/computer/computer download --computer COMPUTER_ID --source /workspace/result.zip --destination output/result.zip
```

Transfers preserve exact bytes without opening a terminal. Local paths resolve
from the CLI's current directory, or may be absolute within that bot's workspace.
The broker independently restricts access to the workspace and refuses symlinks
in local paths. Guest paths must be absolute. Parent folders must exist and an
existing destination is never replaced. Regular files up to 8 GiB are supported;
archive directories before transferring them. Files arrive with private permissions;
set guest executable permissions separately when needed.

Success JSON includes `path` (guest), `localPath` (workspace-relative), and
`byteCount`. `list` exposes provider capabilities; these commands require
`file-transfer-v1`. Older providers remain usable for existing terminal/display
commands and return an update message for transfers.

Noodle's computer picker also shows “Update Noodle Computer to enable file
transfers” as soon as discovery finds a compatible provider missing that feature.
Open Noodle Computer from the notice and choose **Check for Updates…** in its app
menu. The notice clears when the refreshed provider supports transfers; existing
terminals and displays remain usable while the update is pending.

The broker assigns a fresh transfer UUID and stages the payload in the apps'
existing private App Group. Only the UUID and guest path cross the authenticated
socket; agents cannot select provider host paths. The provider streams bytes
through its bundled guest helper. The broker removes staging after success or
failure and expires crash leftovers after one hour. Downloads are published
atomically only after a complete copy and a fresh assignment check. Transfers
time out after ten minutes; an upload with an uncertain result is never retried
automatically. Check the guest destination before retrying.

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
swift test --disable-sandbox --filter ComputerTransferTests
swift test --disable-sandbox --filter ComputerBrokerTransferTests
swift test --disable-sandbox --filter ComputerAgentFilesTests
```

For guest integration, launch the signed Computer executable with
`--noodle-background --provider-integration-test`. After `PROVIDER TEST READY`,
launch the signed Noodle executable with `--computer-integration-test`.
These use temporary libraries and test assignment, binary and empty-file CLI
transfers, overwrite/path errors, terminals, revocation, and cards.
The provider cleans up after completion or ten minutes.

The broker suite also runs under the ordinary root `swift test` and CI. It uses
real workspace IPC, file I/O and assignment checks with a controlled provider
connection to test interrupted uploads/downloads, revocation during a transfer,
concurrent agents, forged envelopes, incorrect byte counts and older providers.
Concurrent IPC reader/writer tests also check that scanners only see complete
JSON messages, and that publication never follows a destination symlink.
These tests require no signing identity or running guest. The signed guest
fixture above verifies the actual transport and sandbox boundary separately.

Noodle's `--computer-picker-test` opens an isolated assignment UI fixture. Add
`--computer-update-notice-test` to save a before/after update notice snapshot using
synthetic providers, without opening real computers or bot workspaces.
Computer's `--provider-snapshot-test`, alongside its provider integration flags,
checks native desktop capture. Snapshot and preview geometry checks are in
`Computer/Tests/PreviewSnapshotTests.swift` and `PreviewGeometryTests.swift`.

[Computer](../README.md) · [Architecture](../../docs/architecture.md)
