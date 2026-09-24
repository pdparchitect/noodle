# Releasing Noodle Browser

Browser releases independently from Noodle, using `Browser/VERSION` and
`Browser/CHANGELOG.md`. Only publish when explicitly requested.

## Publish

1. Set a higher, unused `X.Y.Z` in `Browser/VERSION`.
2. Move the relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD` in `Browser/CHANGELOG.md`.
3. Run the local checks below, commit, and push to `main`. The version change requests publication.
4. Watch **Validate and release versions** through completion and verify the download channel.

The [shared release pipeline](../docs/releases.md) tests, signs, notarizes, staples,
and verifies the app before creating `browser-vX.Y.Z`. It publishes the exact
prepared ZIP and DMG and updates `browser-latest`. PRs and local builds do not publish.
A new Browser version with only Unreleased notes stays in development until its
first dated release section is prepared, just like the other companions.

Browser uses the same signing secrets and Sparkle key as Noodle, Computer, and
Applet. The apps must use the same signing team for integration. Downloads and
update assets must be public.

## Downloads and updates

- Versioned release: `browser-vX.Y.Z`, containing `Noodle-Browser-arm64.zip`, `Noodle-Browser-arm64.dmg`, their checksums, signed `appcast.xml`, and notes.
- [Download channel](https://github.com/pdparchitect/noodle/releases/tag/browser-latest): copies of the current release's assets.
- [Direct ZIP download](https://github.com/pdparchitect/noodle/releases/download/browser-latest/Noodle-Browser-arm64.zip): available after the first release.
- [Direct DMG download](https://github.com/pdparchitect/noodle/releases/download/browser-latest/Noodle-Browser-arm64.dmg): available after the first release with disk images.
- [Update feed](https://github.com/pdparchitect/noodle/releases/download/browser-latest/appcast.xml): points to the immutable versioned archive.

Both releases use `--latest=false`, preserving Noodle as the repository's latest
release. Version tags identify source commits; `browser-latest` is a channel marker.

Release builds offer **Noodle Browser → Check for Updates…** and **Settings → Update**.
Local builds disable update checks. Automatic installation is opt-in. Updating
restarts the app: website data and saved tab URLs persist, but live page state and
unsent forms do not. Save your work before updating.

Bundle verification checks the main app's exact sandbox entitlements, Sparkle
installer boundary, signatures, framework links, and signed update feed.

## Failure and recovery

Use the [shared recovery process](../docs/releases.md#recover-a-failed-release).
Prepared artifacts are retained for seven days. Never rebuild to replace a
published archive, move a version tag, or overwrite versioned assets.

If the versioned release succeeded but channel promotion failed, inspect and verify
that release's ZIP, DMG, and checksums. Promote those existing assets to
`browser-latest`, then its signed feed, title, and notes, in that order. Only the
channel's copies may be replaced. Preserve all versioned releases and unrelated
channel attachments.

## Local checks

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Browser --scratch-path .build/browser
swift test --disable-sandbox --filter 'BrowserBrokerTests|CompanionAssignmentPickerTests|MessengerDocumentationTests'
swift Browser/Tests/ReleaseWorkflowTests.swift "$PWD"
python3 -m unittest discover -s Tests/ReleaseAutomation -v
NOODLE_BROWSER_DATA_CONTAINER=development zsh scripts/xcode-build.sh Browser
zsh scripts/verify-browser-release.sh '.build/Noodle Browser Dev.app'
zsh scripts/test-browser.sh '.build/Noodle Browser Dev.app'
zsh scripts/test-browser-ui.sh '.build/Noodle Browser Dev.app'
```

The release archives the same Xcode project with `xcodebuild archive`, signs with Developer ID,
timestamps every signature and turns updates on; see `scripts/package-xcode-release.sh`, shared with
Applet and the Hub.

The signed browser fixtures use disposable profiles and a local fake site. Release
preparation runs them against the production bundle before uploading any assets,
after `scripts/verify-launch-hooks.sh` confirms it carries no development hooks and
spells no launch check.
The UI fixture opens its own test window. Local checks do not replace CI
notarization and distribution checks.

[Browser](README.md)
