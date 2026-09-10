# Releasing Noodle Computer

Computer is a separate product. `Computer/VERSION` and `Computer/CHANGELOG.md`
own its version and release notes. Standard Noodle's `VERSION`, changelog,
`v*` tags and repository-wide latest release stay independent.

Nothing is published by a local build. Publishing requires explicit approval,
approved dated release notes and a pushed `computer-vX.Y.Z` tag. The initial
notes remain Unreleased deliberately.

## Publish an approved release

1. Set `Computer/VERSION` to a new `X.Y.Z`. Never reuse a published version.
2. Move the approved notes into `## [X.Y.Z] - YYYY-MM-DD` in
   `Computer/CHANGELOG.md`, and commit the intended changes.
3. Run `zsh scripts/create-computer-release-tag.sh`. It requires a clean worktree,
   refuses existing tags, and pushes only the new Computer tag.
4. The `Release Noodle Computer` workflow runs Computer, protocol and Noodle
   tests, imports the existing publisher's Developer ID identity, builds with a
   secure timestamp, verifies the signed bundle, notarizes, staples and checks
   Gatekeeper acceptance. It signs the final ZIP and feed using Sparkle 2.9.4.
5. The versioned GitHub release is uploaded as a draft and made public only
   after all assets exist. The `computer-latest` channel is updated afterward.

The workflow uses the same existing secret names as Noodle:
`MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`,
`APP_STORE_CONNECT_API_KEY_P8`, `APP_STORE_CONNECT_KEY_ID`,
`APP_STORE_CONNECT_ISSUER_ID`, and `SPARKLE_PRIVATE_KEY`.
The shared publisher update key matches the pinned public key; do not rotate
either application's embedded key casually. Noodle and Computer must use the
same signing team for their authenticated integration.

Signing material is created only in the ephemeral runner's private temporary
directory and keychain, then removed on success or failure. The public-release
workflow refuses a private repository: downloads and Sparkle are unauthenticated
and must not require a GitHub token embedded in either app.

## Downloads and update isolation

- Immutable archive: `Noodle-Computer-X.Y.Z-arm64.zip` under `computer-vX.Y.Z`,
  with SHA-256 checksum, signed `appcast.xml`, and release notes.
- Stable download page: `https://github.com/pdparchitect/noodle/releases/tag/computer-latest`.
  Its notes link directly to the latest immutable ZIP. The channel tag is a
  marker, not the source revision for later versions; use version tags for source.
- Computer feed: `https://github.com/pdparchitect/noodle/releases/download/computer-latest/appcast.xml`.
- Both Computer releases use `--latest=false`. They must never replace the
  standard Noodle latest-release feed.

Noodle's **Get Noodle Computer…** checks for the public channel, then opens its
download page in the user's browser. Before first publication, it explains that
no public download exists and offers the project/build instructions. Errors and
rate limits are reported rather than starting an unverified download. No silent
installer or filesystem access is added to Noodle. Users unzip the download,
move the app to Applications and return to Noodle; discovery refreshes there.

## Updater and sandbox boundary

Release builds enable **Computer → Check for Updates…** and an automatic-check
toggle. Local development/test builds leave update checks disabled. The updater
starts on user activation, not on a quiet agent-driven provider launch.
Daily checks are enabled by default; automatic installation is disabled. The
user chooses installation through Sparkle. Save guest work first: updating
terminates Computer through its normal guest-shutdown lifecycle. Running guests
are not automatically restarted after relaunch.

The approved boundary matches Noodle's Sparkle integration: the main app retains
sandbox, virtualization, outbound network, user-selected read-only imports and
the Computer App Group. Its sole added entitlement is the two exact
`com.pdparchitect.noodle.computer-spks` / `-spki` Mach lookup names. Sparkle's
same-team signed, hardened installer components run outside the app sandbox to
replace the app; they have no application entitlements. The unnecessary
Downloader service is removed. Signed feeds and verification before extraction
are required. `verify-computer-release.sh` checks the exact six-key main-app
policy, version, update settings, nested signatures and bundle-relative linkage.

## Failure and recovery

Packaging uses a fresh product-specific staging directory and refuses existing
output. It does not delete other release assets. Publication refuses an existing
versioned release or a version older than the channel. Failed drafts remain
unpromoted; never overwrite a published ZIP to retry a release.

If a versioned release succeeded but channel promotion failed, inspect that
release and promote its **existing signed feed** and download link; do not rebuild
or replace its ZIP. Channel feed replacement uses GitHub's asset upload with
`--clobber`, so a brief unavailable-feed window is possible during replacement;
failed checks can be retried. The archive enclosure always references the already
published immutable version, never a moving ZIP.

Actual notarization, Gatekeeper distribution acceptance, GitHub publication and
an installed-version-to-new-version update require the first approved release.
Local signing/build tests do not substitute for those end-to-end release checks.

## Local checks

```sh
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
swift test --disable-sandbox --package-path Computer/Bridge
swift test --disable-sandbox
swift Computer/Tests/ReleaseWorkflowTests.swift "$PWD"
zsh scripts/build-computer.sh
zsh scripts/verify-computer-release.sh '.build/Noodle Computer.app'
```

The release workflow tests replace GitHub and git commands with local fixtures;
they verify first publication, upgrade ordering, isolation from Noodle's latest
release, rollback refusal and rejection of private/existing releases without
network access. `--computer-picker-test --computer-download-test` on the Noodle
executable previews the missing-app entry point without uninstalling Computer.
