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

- Versioned release: `computer-vX.Y.Z`, containing `Noodle-Computer-X.Y.Z-arm64.zip`, its checksum, signed `appcast.xml`, and notes.
- [Download channel](https://github.com/pdparchitect/noodle/releases/tag/computer-latest): copies of the current release's assets.
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
2. Copy that existing ZIP and checksum to `computer-latest`.
3. Replace the channel's signed feed, then its title and notes, after the assets exist.
4. Verify the download/feed, then remove only the previous version's ZIP/checksum copies from the channel.

Keep all versioned assets intact. A brief feed interruption is possible during
replacement. Existing drafts or partially promoted channels require inspection;
do not start a new build to recover them. Prepared workflow artifacts last seven days.

## Local checks

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
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

[Computer](README.md)
