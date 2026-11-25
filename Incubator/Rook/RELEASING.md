# Releasing Rook

Rook is incubating and releases on its own: never with Noodle, its companions or the Suite. Use
`Incubator/Rook/VERSION` and `Incubator/Rook/CHANGELOG.md`. Only publish when explicitly requested.

## Publish

1. Set a higher, unused `X.Y.Z` in `Incubator/Rook/VERSION`.
2. Move the relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD` in `Incubator/Rook/CHANGELOG.md`.
3. Run the local checks below, commit, and push to `main`. The dated version requests publication.
4. Watch **Release Rook** through completion and verify the download channel.

**Release Rook** runs when either file changes on `main`, or by hand. It tests RookCore and the app,
signs, notarizes and verifies the app, creates `rook-vX.Y.Z`, publishes the ZIP and DMG with the Setup Guide and User Guide PDFs, and updates
`rook-latest`. A version that is already released, or has no dated section, publishes nothing.

Rook uses the same signing secrets and Sparkle key as Noodle. The repository and release assets must be
public for unauthenticated downloads and updates.

## Downloads and updates

- Versioned release: `rook-vX.Y.Z`, containing `Rook-arm64.zip`, `Rook-arm64.dmg`, their checksums, signed `appcast.xml`, `Rook-Setup-Guide.pdf`, `Rook-User-Guide.pdf`, and notes.
- [Download channel](https://github.com/pdparchitect/noodle/releases/tag/rook-latest): copies of the current release's assets.
- [Direct DMG download](https://github.com/pdparchitect/noodle/releases/download/rook-latest/Rook-arm64.dmg) and [ZIP](https://github.com/pdparchitect/noodle/releases/download/rook-latest/Rook-arm64.zip): fixed URLs available after the first release.
- [Update feed](https://github.com/pdparchitect/noodle/releases/download/rook-latest/appcast.xml): points to the immutable versioned archive.

Both releases use `--latest=false` so they never replace Noodle's latest release.

Release builds offer **Check for Updates** in the Rook menu and check daily. Local builds disable checks.

## Failure and recovery

Follow the [shared recovery steps](../../docs/releases.md#recover-a-failed-release). Never move tags or
replace a published archive. If `rook-vX.Y.Z` exists but `rook-latest` was not updated, copy the
release's verified ZIP, DMG and checksums to `rook-latest`, then its signed feed, then its title and notes.

## Local checks

Run from the repository root:

```sh
swift test --disable-sandbox --package-path Incubator/Rook --scratch-path .build/rook
ROOK_DATA_CONTAINER=production zsh Incubator/Rook/scripts/build.sh
zsh scripts/verify-rook-release.sh .build/Rook.app
zsh scripts/build-guides.sh Rook
```

The release archives the same project with `scripts/package-xcode-release.sh Rook`, signs with
Developer ID, timestamps every signature and turns updates on, on the `xcode-27` image because Rook
ships the Apple harness and its MLX shaders. Local checks do not replace CI notarization.
