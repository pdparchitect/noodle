# Releases and updates

Only publish when explicitly requested. Commands below run from the repository root.

## Prepare a release

Each product has its own version and changelog:

| Product | Version | Release notes | Generated tag |
| --- | --- | --- | --- |
| Noodle | `VERSION` | `CHANGELOG.md` | `vX.Y.Z` |
| Computer | `Computer/VERSION` | `Computer/CHANGELOG.md` | `computer-vX.Y.Z` |
| Images | `Computer/Images/VERSION` | `Computer/Images/CHANGELOG.md` | `computer-images-vX.Y.Z` |

1. Set the product's version to an unused, higher `X.Y.Z`.
2. Move its relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD`. Leave unrelated work under Unreleased. These notes become the release description.
3. Run the affected tests and review the changes.
4. Commit and push to `main`. **Pushing a new version requests publication.**
5. Watch **Validate and release versions** through completion and verify the public download and update channel.

Do not create tags manually or reuse published versions. Unchanged versions skip
publication. PRs validate and test without publishing. A manual workflow run on
`main` reads the same version files.

See [Computer releases](../Computer/RELEASING.md) for its separate download channel
and [image releases](../Computer/Images/README.md#publish) for registry checks.

## What CI does

All selected products must pass tests and preparation before any tag is created.
App preparation includes signing, notarization, stapling, Gatekeeper, and Sparkle
verification. Image preparation builds and tests both ARM64 images. Tests are
scoped by product; Computer releases also run Noodle integration coverage.

CI tags the checked commit and publishes the exact prepared artifacts. When
released together, images publish first, then Computer, then Noodle. App releases
remain drafts until their ZIP, checksum, signed feed, and notes are uploaded.
A successful run requires every selected product to finish publishing.
Computer releases never replace Noodle's repository-wide latest release.

## Recover a failed release

- **Checks or preparation failed:** fix the cause and rerun the original workflow's failed jobs. No selected tags are created before all preparation passes.
- **Tagged but publication skipped:** run **Publish verified release artifacts** with the original run ID. It validates the original checks, tags, and checksums before publishing saved artifacts.
- **Publication partly completed:** inspect existing drafts, assets, and channels before retrying. Follow [Computer channel recovery](../Computer/RELEASING.md#failure-and-recovery) where applicable.

Prepared artifacts are retained for seven days. Reuse them; never rebuild to replace
a published archive or delete/move tags. Image retries must match the tested config
digest. GitHub and GHCR publication can fail independently after tagging.

## Signing secrets

GitHub Actions uses these encrypted secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

CI removes temporary signing material after use. Keep keys out of the repository.
Back up the Sparkle key securely; changing it requires Sparkle's key-transition
procedure so existing installations can still update. Both apps must use the same
signing team for Computer integration. Downloads must be public; the apps contain
no GitHub token.

## In-app updates

Use **Noodle → Check for Updates…** or **Settings → Update**. Daily checks are on
by default; automatic download/install is a separate opt-in.

Save drafts and editor changes before **Install and Relaunch**. It restarts
immediately through the normal harness shutdown/recovery process; unsaved work
can be lost.

Noodle reads the [latest release feed](https://github.com/pdparchitect/noodle/releases/latest/download/appcast.xml).
Its archive links point to immutable versioned releases. Publish only stable
Noodle releases as the repository's latest release.

[Documentation](README.md)
