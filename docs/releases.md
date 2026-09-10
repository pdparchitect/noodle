# Releases and updates

Noodle Computer has a separate [release process](../Computer/RELEASING.md),
version, changelog, `computer-v*` tags and update feed. Its releases never become
the repository-wide latest release used by standard Noodle below.

Commands and project paths below are relative to the repository root.

The root `VERSION` file is the canonical stable application version (`X.Y.Z`). Swift Package Manager describes the package and deployment target, but it does not provide a macOS app marketing version. Starting with the updater bootstrap, the build copies `VERSION` into both `CFBundleShortVersionString` and `CFBundleVersion`, so local builds and CI releases use the same ordering. Increase it for every release; never reuse a published version. `NOODLE_BUILD_NUMBER` is a local-testing override only; release packaging always uses `VERSION`.

`CHANGELOG.md` owns the user-facing release notes. To release, increment
`VERSION`, move the relevant Unreleased entries into a dated
`## [X.Y.Z] - YYYY-MM-DD` section, commit, and push to `main`. Publishing is an
explicit release action: merging or pushing a new version requests publication.
Do not create tags by hand. The workflow derives `vX.Y.Z` directly from `VERSION`.

The **Validate and release versions** workflow handles all three independent
version files: `VERSION`, `Computer/VERSION`, and `Computer/Images/VERSION`.
An unchanged version does not release again. New versions must exceed their
product's existing version tags and have nonempty dated release notes. PRs run
validation and tests without creating tags or publishing. A manual workflow run
on `main` follows the same checks and reads the same files; it has no version input.

All selected products must pass the shared application/integration tests and
finish their preparation before any tag is minted. Application preparation
includes signing, notarization, stapling, Gatekeeper checks, and Sparkle archive
and feed verification. Image preparation builds both ARM64 images and verifies
their contracts, interactive terminals, wallpaper and window rendering. The
prepared app archives and container images are saved as workflow artifacts.
The gate accepts skipped preparation only for products whose version is unchanged.
A failed or cancelled required job prevents every selected tag and publication.

After that gate, the workflow atomically pushes the derived tags at the checked
source commit. Existing tags are never moved; retries accept only tags already
pointing to that commit. Publication continues in the same pipeline using the
exact prepared artifacts, because tags pushed by `GITHUB_TOKEN` do not trigger
another workflow. No personal access token or separate tagging workflow is needed.
Images publish first, followed by Computer, then Noodle when those products are
selected together. Public image references are verified before Computer ships.
Computer's channel never replaces Noodle's repository-wide latest release.

Each app release stays a draft until its ZIP, checksum, signed appcast and
changelog notes have uploaded, then its update channel is promoted. External
publication can still fail after the checks and tags succeed; GitHub and GHCR
are not a single transaction. Re-run failed jobs in the original workflow to
reuse its prepared artifacts (retained for seven days). Do not start a fresh
build to replace an immutable published archive. Existing drafts and partially
promoted app channels require inspection and recovery from their existing assets;
see [Computer recovery](../Computer/RELEASING.md#failure-and-recovery). An image
retry accepts an existing version only when its config digest matches the exact
tested build. Never delete or move tags to retry a release.

The release workflow reads signing material only from encrypted GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

The `.p12` secret is used only for code signing; the App Store Connect API key is used only for notarization. The dedicated Sparkle Ed25519 private key signs update archives and feeds; only its public key is embedded in the app. No certificate, private key, password, or notarization credential belongs in the repository. Temporary CI signing material is removed on success or failure.

### In-app updates

Use **Noodle → Check for Updates…** or **Settings → Update**. Automatic daily checks are enabled by default. Automatic download/installation is a separate opt-in setting. Sparkle provides release prompts, progress, signature validation, installation, and relaunch. **Install and Relaunch** proceeds without Noodle checking agent status, drafts, attachments, or open editors, and without an additional confirmation. Harnesses follow the normal shutdown and recovery lifecycle. Unsent drafts and unsaved editor changes are not saved by the updater and can be lost on restart.

The app fetches `https://github.com/pdparchitect/noodle/releases/latest/download/appcast.xml`; its enclosures point to versioned ZIP assets in the same GitHub repository. There is no separate server, GitHub Pages site, access token in the app, or custom download service. Only publish stable releases as “latest.” The previous release remains available while CI builds and uploads the next one.

Sparkle is pinned to 2.9.4 in `Package.swift` and `Package.resolved`, from [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle). Its complete upstream licence is copied into the signed app's Resources. To regenerate a feed locally without exporting the dedicated Keychain key, use the bundled `generate_appcast --account com.pdparchitect.noodle` tool. Back up the signing key securely: losing it prevents straightforward updates for existing installations. Never rotate the embedded public key without following Sparkle's key-transition procedure.

Release assets must be accessible to the app for update checks and downloads to work. While the repository is private, the unauthenticated updater cannot fetch those assets; the app does not embed a GitHub access token.


---

[Documentation](README.md) · [Noodle](../README.md)
