# Releasing Noodle Computer

Computer is a separate product. `Computer/VERSION` and `Computer/CHANGELOG.md`
own its version and release notes. Standard Noodle's `VERSION`, changelog,
`v*` tags and repository-wide latest release stay independent.

Nothing is published by a local build. `Computer/VERSION` is the only source
of the Computer version; its Git tag is derived automatically after validation.

## Publish an approved release

1. Set `Computer/VERSION` to a new `X.Y.Z`. Never reuse a published version.
2. Move the approved notes into `## [X.Y.Z] - YYYY-MM-DD` in
   `Computer/CHANGELOG.md`, commit the intended changes, and push to `main`.
   Pushing the version change requests publication; no manual tag is required.
3. **Validate and release versions** runs Computer, protocol and Noodle tests.
   The Computer preparation workflow imports the existing publisher's Developer
   ID identity, builds with a secure timestamp, verifies the signed bundle,
   notarizes, staples, checks Gatekeeper acceptance, and verifies the real updater
   menu/settings. Sparkle 2.9.4 signs the final ZIP and feed.
4. Only after every selected product's checks and preparation pass does the
   workflow mint `computer-vX.Y.Z` from the file. It then publishes the exact
   prepared archive; it does not rebuild after tagging. If image versions change
   in the same push, both tested images publish and pass anonymous registry
   verification before the Computer app is published.
5. The versioned GitHub release is uploaded as a draft and made public only
   after all assets exist. The `computer-latest` channel is updated afterward.

Unchanged versions skip release work. PRs validate without publishing. See the
[shared release pipeline](../docs/releases.md) for gating and retry behavior.

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
  Its Assets include the current version's ZIP, checksum and signed feed. Its
  notes also link directly to the immutable ZIP. The channel tag is a
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

Release builds enable **Computer → Check for Updates…** and **Settings → Update**,
matching Noodle's update controls. Local development/test builds leave update checks disabled. The updater
starts on user activation, not on a quiet agent-driven provider launch.
Daily checks are enabled by default; automatic download/install is available as
an explicit opt-in and remains off by default. Save guest work first: updating
terminates Computer through its normal guest-shutdown lifecycle. Running guests
are not automatically restarted after relaunch.

The approved boundary matches Noodle's Sparkle integration: the main app retains
sandbox, virtualization, outbound network, user-selected read/write imports/exports and
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
release and copy its **existing ZIP, checksum and signed feed** to the channel;
do not rebuild or replace its immutable ZIP. Verify the ZIP against its checksum
before uploading and update the channel notes/title only after all assets exist.
Channel upgrades upload both new download assets before replacing the feed and
notes, then remove only the preceding version's ZIP/checksum copies from the
channel. Versioned release assets remain untouched. Channel feed replacement uses
GitHub's asset upload with `--clobber`, so a brief unavailable-feed window is possible during replacement;
failed checks can be retried. The archive enclosure always references the already
published immutable version, never a moving ZIP.

Local signing/build tests do not substitute for notarization, Gatekeeper
distribution acceptance, publication, or an installed-version-to-new-version
update. The pipeline performs the distribution checks on its prepared archive.

## Local checks

```sh
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
swift test --disable-sandbox --package-path Computer/Bridge
swift test --disable-sandbox
swift Computer/Tests/ReleaseWorkflowTests.swift "$PWD"
zsh scripts/build-computer.sh
zsh scripts/verify-computer-release.sh '.build/Noodle Computer.app'
".build/Noodle Computer.app/Contents/MacOS/NoodleComputer" --updater-ui-test
```

The release workflow tests replace GitHub and git commands with local fixtures;
they verify first publication, upgrade ordering, isolation from Noodle's latest
release, rollback refusal and rejection of private/existing releases without
network access. `--computer-picker-test --computer-download-test` on the Noodle
executable previews the missing-app entry point without uninstalling Computer.

The release pipeline opens the actual application menu and Settings scene before
publication. For local isolated UI checks, build with `NOODLE_COMPUTER_TEST_BUILD=1`;
add `NOODLE_COMPUTER_TEST_UPDATES=1` only to exercise real Sparkle controls in that
test bundle. This flag is rejected for production bundles. Never install an update
or restart the user's running computers as part of a UI check.
