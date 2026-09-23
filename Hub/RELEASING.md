# Releasing Noodle Hub

Hub releases independently from Noodle. Use `Hub/VERSION` and
`Hub/CHANGELOG.md`. Only publish when explicitly requested.

## Publish

1. Set a higher, unused `X.Y.Z` in `Hub/VERSION`.
2. Move the relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD` in `Hub/CHANGELOG.md`.
3. Run the local checks below, commit, and push to `main`. The version change requests publication.
4. Watch **Validate and release versions** through completion and verify the download channel.

The [shared release pipeline](../docs/releases.md) tests, signs, notarizes, and
verifies the app before creating `hub-vX.Y.Z`. It publishes the prepared ZIP and
DMG and updates `hub-latest`. PRs and local builds do not publish. The Hub ships
Noodle's runtime and helpers, so its preparation also waits for Noodle's tests.

Hub uses the same signing secrets and Sparkle key as Noodle. The repository and
release assets must be public for unauthenticated downloads and updates.

## Downloads and updates

- Versioned release: `hub-vX.Y.Z`, containing `Noodle-Hub-arm64.zip`, `Noodle-Hub-arm64.dmg`, their checksums, signed `appcast.xml`, and notes.
- [Download channel](https://github.com/pdparchitect/noodle/releases/tag/hub-latest): copies of the current release's assets.
- [Direct DMG download](https://github.com/pdparchitect/noodle/releases/download/hub-latest/Noodle-Hub-arm64.dmg) and [ZIP](https://github.com/pdparchitect/noodle/releases/download/hub-latest/Noodle-Hub-arm64.zip): fixed URLs available after the first release.
- [Update feed](https://github.com/pdparchitect/noodle/releases/download/hub-latest/appcast.xml): points to the immutable versioned archive.

Both releases use `--latest=false` so they never replace Noodle's latest release.
Use version tags to identify source commits; `hub-latest` is a channel marker.

Release builds offer **Check for Updates…** in the Hub's menu and check daily.
Local builds disable checks.

Sparkle's signed installer replaces the app outside its sandbox. Bundle verification
checks the app's exact entitlements, installer boundary, signatures, and feed.

## Failure and recovery

Follow the [shared recovery steps](../docs/releases.md#recover-a-failed-release).
Never move tags or replace a published archive.

If the versioned release exists but channel promotion failed:

1. Inspect the existing release and verify its ZIP and DMG against their checksums.
2. Copy those existing ZIP, DMG, and checksum files to `hub-latest`, replacing only the channel's fixed-name copies.
3. Replace the channel's signed feed, then its title and notes, after the assets exist.
4. Verify the download and feed.

Keep all assets on version tags intact. Existing drafts or partially promoted
channels require inspection; do not start a new build to recover them. Prepared
workflow artifacts last seven days.

## Local checks

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Hub --scratch-path .build/hub
swift test --disable-sandbox
swift Hub/Tests/ReleaseWorkflowTests.swift "$PWD"
zsh scripts/build-hub.sh
# The release packaging script sets NOODLE_HUB_DATA_CONTAINER=production.
zsh scripts/verify-hub-release.sh '.build/Noodle Hub Dev.app'
```

`verify-hub-release.sh` also runs `scripts/verify-launch-hooks.sh` on a production
bundle: it carries no development hooks and names no launch check.

Local checks do not replace CI notarization and distribution checks.

[Hub](README.md)
