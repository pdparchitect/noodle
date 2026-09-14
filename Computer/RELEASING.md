# Releasing Noodle Computer

Computer releases independently from Noodle. Use `Computer/VERSION` and
`Computer/CHANGELOG.md`. Only publish when explicitly requested.

## Publish

1. Set a higher, unused `X.Y.Z` in `Computer/VERSION`.
2. Move the relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD` in `Computer/CHANGELOG.md`.
3. Run the local checks below, commit, and push to `main`. The version change requests publication.
4. Watch **Validate and release versions** through completion and verify the download channel.

The [shared release pipeline](../docs/releases.md) tests, signs, notarizes, and
verifies the app before creating `computer-vX.Y.Z`. It publishes the prepared
archive and updates `computer-latest`. If images release in the same push, they
must publish and pass anonymous registry checks first. PRs and local builds do
not publish.

Computer uses the same signing secrets and Sparkle key as Noodle. Both apps must
use the same signing team for integration. The repository and release assets
must be public for unauthenticated downloads and updates.

## Downloads and updates

- Versioned release: `computer-vX.Y.Z`, containing `Noodle-Computer-arm64.zip`, its checksum, signed `appcast.xml`, and notes.
- [Download channel](https://github.com/pdparchitect/noodle/releases/tag/computer-latest): copies of the current release's assets.
- [Direct ZIP download](https://github.com/pdparchitect/noodle/releases/download/computer-latest/Noodle-Computer-arm64.zip): a fixed URL available after the first release with the new filename.
- [Update feed](https://github.com/pdparchitect/noodle/releases/download/computer-latest/appcast.xml): points to the immutable versioned archive.

Both releases must use `--latest=false` so they never replace Noodle's latest
release. Use version tags to identify source commits; `computer-latest` is a
channel marker.

Release builds offer **Computer → Check for Updates…** and **Settings → Update**.
Local builds disable checks. Quiet provider launches do not start the updater.
Updating stops guests; they are not automatically restarted after relaunch.

Sparkle's signed installer replaces the app outside its sandbox. Bundle verification
checks the main app's exact entitlements, installer boundary, signatures, and feed.

## Failure and recovery

Follow the [shared recovery steps](../docs/releases.md#recover-a-failed-release).
Never move tags or replace a published archive.

If the versioned release exists but channel promotion failed:

1. Inspect the existing release and verify its ZIP against its checksum.
2. Copy that existing ZIP and checksum to `computer-latest`, replacing only the channel's fixed-name copies.
3. Replace the channel's signed feed, then its title and notes, after the assets exist.
4. Verify the download/feed. When migrating from versioned filenames, remove only the previous version's ZIP/checksum copies from the channel; keep the new fixed-name assets.

Keep all assets on version tags intact. A brief download or feed interruption is possible during
replacement. Existing drafts or partially promoted channels require inspection;
do not start a new build to recover them. Prepared workflow artifacts last seven days.

## Local checks

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
swift test --disable-sandbox --package-path Computer/LocalMac --scratch-path .build/localmac
swift test --disable-sandbox --package-path Computer/Bridge
swift test --disable-sandbox
swift Computer/Tests/ReleaseWorkflowTests.swift "$PWD"
zsh scripts/build-computer.sh
zsh scripts/verify-computer-release.sh '.build/Noodle Computer.app'
'.build/Noodle Computer.app/Contents/MacOS/NoodleComputer' --updater-ui-test
```

For isolated updater UI checks, build with `NOODLE_COMPUTER_TEST_BUILD=1` and
`NOODLE_COMPUTER_TEST_UPDATES=1`. The latter is rejected for production bundles.
Check controls without installing updates or restarting the user's computers.
Local checks do not replace CI notarization and distribution checks.

## Local Mac validation

The creation menu has separate entries for New Container, New from Container
Image, and New Local Mac. Local Mac uses the same appearance and automatic-start
preferences, without image, CPU, memory-allocation or virtual-disk controls.

Local Mac's account-free boundary, file and update-recovery tests are part of the
required Computer CI job. A signed build must also pass the helper identity,
layout and entitlement checks in `verify-computer-release.sh`.

For a native creation-form preview without creating a computer or account, build
with `NOODLE_COMPUTER_TEST_BUILD=1` and run the test app with
`--localmac-creation-preview`. It uses a temporary empty library, renders the form,
prints its PNG path and exits; it never presses Create or registers the service.

Before distributing the first Local Mac release, validate the signed candidate
in the retained account: permissions for capture/input and Documents, human
desktop/terminal/files, assigned-agent terminal and transfers, native preview
opening, quit/reconnect, helper failure, sleep/wake, reboot, and a real signed
old-to-new app update. Check that account identity, files and grants survive and
the main desktop remains unaffected. A prototype service lacking the update
handshake may need a normal Mac restart. A development-to-Developer-ID upgrade
also needs the native Login Items toggle to refresh the saved launch constraint,
and may need that account credential's trusted application updated in Keychain
Access. Keep the password hidden and unchanged; never grant all applications
access. Desktop privacy approvals can also retain the development certificate
even when System Settings reports a new grant. Verify accepted capture and input
in the running helper; the narrowly scoped recovery is documented in
`LocalMac/README.md`. Verify this migration separately from release-to-release
updates.

Keep one account for development and upgrades. Use a separate test machine for
fresh-account setup, deletion and alternate display arrangements when available.
Passing unit tests does not establish compatibility with an untested macOS build;
the background login API is private. Record actual OS and display configurations
and results in `LocalMac/README.md`; do not claim those live checks from a build.

[Computer](README.md)
