# Releasing Pion

Pion is incubating and releases on its own: never with Noodle, its companions or the Suite. Use
`Incubator/Pion/VERSION` and `Incubator/Pion/CHANGELOG.md`. Only publish when explicitly requested.

## Publish

1. Set a higher, unused `X.Y.Z` in `Incubator/Pion/VERSION`.
2. Move the relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD` in `Incubator/Pion/CHANGELOG.md`.
3. Run the local checks below, commit, and push to `main`. The dated version requests publication.
4. Watch **Release Pion** through completion and verify the download channel.

**Release Pion** runs when either file changes on `main`, or by hand. It tests PionCore and the app,
signs, notarizes and verifies the app, creates `pion-vX.Y.Z`, publishes the ZIP and DMG with the Setup Guide and User Guide PDFs, and updates
`pion-latest`. A version that is already released, or has no dated section, publishes nothing.

Pion uses the same signing secrets and Sparkle key as Noodle. The repository and release assets must be
public for unauthenticated downloads and updates.

## Downloads and updates

- Versioned release: `pion-vX.Y.Z`, containing `Pion-arm64.zip`, `Pion-arm64.dmg`, their checksums, signed `appcast.xml`, `Pion-Setup-Guide.pdf`, `Pion-User-Guide.pdf`, and notes.
- [Download channel](https://github.com/pdparchitect/noodle/releases/tag/pion-latest): copies of the current release's assets.
- [Direct DMG download](https://github.com/pdparchitect/noodle/releases/download/pion-latest/Pion-arm64.dmg) and [ZIP](https://github.com/pdparchitect/noodle/releases/download/pion-latest/Pion-arm64.zip): fixed URLs available after the first release.
- [Update feed](https://github.com/pdparchitect/noodle/releases/download/pion-latest/appcast.xml): points to the immutable versioned archive.

Both releases use `--latest=false` so they never replace Noodle's latest release.

Release builds offer **Check for Updates** in the Pion menu and check daily. Local builds disable checks.

## Failure and recovery

Follow the [shared recovery steps](../../docs/releases.md#recover-a-failed-release). Never move tags or
replace a published archive. If `pion-vX.Y.Z` exists but `pion-latest` was not updated, copy the
release's verified ZIP, DMG and checksums to `pion-latest`, then its signed feed, then its title and notes.

## Local checks

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Incubator/Pion --scratch-path .build/pion
PION_DATA_CONTAINER=production zsh Incubator/Pion/scripts/build.sh
zsh scripts/verify-pion-release.sh .build/Pion.app
zsh scripts/build-guides.sh Pion
```

The release archives the same project with `scripts/package-xcode-release.sh Pion`, signs with
Developer ID, timestamps every signature and turns updates on, on the `xcode-27` image because Pion
ships the Apple harness and its MLX shaders. Local checks do not replace CI notarization.
