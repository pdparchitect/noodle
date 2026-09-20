# Releases and updates

Only publish when explicitly requested. Commands below run from the repository root.

## Prepare a release

Each product has its own version and changelog:

| Product | Version | Release notes | Generated tag |
| --- | --- | --- | --- |
| Noodle | `VERSION` | `CHANGELOG.md` | `vX.Y.Z` |
| Computer | `Computer/VERSION` | `Computer/CHANGELOG.md` | `computer-vX.Y.Z` |
| Applet | `Applet/VERSION` | `Applet/CHANGELOG.md` | `applet-vX.Y.Z` |
| Browser | `Browser/VERSION` | `Browser/CHANGELOG.md` | `browser-vX.Y.Z` |
| Images | `Computer/Images/VERSION` | `Computer/Images/CHANGELOG.md` | `computer-images-vX.Y.Z` |

1. Set the product's version to an unused, higher `X.Y.Z`.
2. Move its relevant Unreleased notes into `## [X.Y.Z] - YYYY-MM-DD`. Leave unrelated work under Unreleased. These notes become the release description.
3. Run the affected tests and review the changes.
4. Commit and push to `main`. **Pushing a new version requests publication.**
5. Watch **Validate and release versions** through completion and verify the public download and update channel.
6. Verify the website's [Noodle download](https://github.com/pdparchitect/noodle/releases/latest/download/Noodle-arm64.dmg) and [Suite download](https://github.com/pdparchitect/noodle/releases/download/suite-latest/Noodle-Suite-arm64.dmg). Suite completion triggers website deployment; the website waits until both downloads exist. **Deploy website** can also be run manually.

Do not create tags manually or reuse published versions. Unchanged versions skip
publication. A new product with no release history and only Unreleased notes
remains in development until its first dated version section is prepared. PRs validate and test without publishing. A manual workflow run on
`main` reads the same version files.

See [Computer releases](../Computer/RELEASING.md), [Applet releases](../Applet/RELEASING.md), and [Browser releases](../Browser/RELEASING.md)
for their separate download channels, and [image releases](../Computer/Images/README.md#publish) for registry checks.

## Download filenames

App ZIPs use fixed filenames: `Noodle-arm64.zip`, `Noodle-Computer-arm64.zip`,
`Noodle-Applet-arm64.zip`, and `Noodle-Browser-arm64.zip`, each with a matching `.zip.sha256` file.
Each app also ships a signed, notarized disk image with the same basename and
`.dmg` extension, plus a `.dmg.sha256` checksum. Open the DMG and drag the app to
Applications. The installer uses a 660 × 400 Finder window, 160-point icons,
16-point labels, and a Retina background with a chevron between the icons.
Versions remain in app metadata, release titles and tags. Signed update feeds
use immutable tag URLs, such as `releases/download/vX.Y.Z/Noodle-arm64.zip`;
the website uses `releases/latest/download/Noodle-arm64.dmg`. Generated app release
notes lead with a DMG download link and offer ZIP as an alternative; both links
point to that release's immutable tag. Companion download channels use the same
DMG-first order.

Keep previously published archives and feed URLs intact. Migration feeds and
publication recovery accept the old versioned filenames as well as the new names,
including older prepared runs without disk images.

To preview an installer locally without release credentials, use a signed local
build (ad-hoc signing is sufficient):

```sh
zsh scripts/package-dmg.sh --preview ".build/Noodle Dev.app" .build/dmg-preview/Noodle.dmg
open .build/dmg-preview/Noodle.dmg
```

The preview image itself is unsigned and is not a release artifact. Packaging
installs pinned Python build tools into `.build/dmg-tools` and renders the
background with AppKit. Finder layout is written directly, so CI needs no Finder
automation or interactive desktop. Existing output is never overwritten.

## What CI does

All selected products must pass tests and preparation before any tag is created.
App preparation includes signing, notarization, stapling, Gatekeeper, and Sparkle
verification. Image preparation builds and tests both ARM64 images. Tests are
scoped by product; Computer, Applet, and Browser releases also run Noodle integration coverage.

CI tags the checked commit and publishes the exact prepared artifacts. When
released together, images publish first, then Computer, then Noodle. Applet and Browser publish independently of images and before Noodle. App releases
remain drafts until their ZIP, DMG, checksums, signed feed, and notes are uploaded.
DMGs are built from the same stapled apps as the ZIPs, then signed, notarized,
stapled, and assessed by Gatekeeper before their checksums are generated. They are
created after Sparkle feed generation so automatic updates continue using ZIPs.
A successful run requires every selected product to finish publishing.
Computer, Applet, and Browser releases never replace Noodle's repository-wide latest release.

Noodle preparation uses GitHub's official [`xcode-27` image](https://github.com/actions/runner-images/issues/14404)
and requires SDK 27 so the downloaded app includes the newer Apple and MLX features.
The image is currently a public preview and may queue while capacity is limited.
Shader packaging uses the helper's compile-time capabilities, since a macOS 26
build host cannot report macOS 27 model availability. The main regression suites
continue on macOS 26; live macOS 27 inference checks require a compatible host.

Automatic app CI skips changes limited to ordinary Markdown, `docs/` assets,
or `website/`. Changelogs remain release inputs. Source,
test, build, workflow, and version changes continue to run CI, including commits
that also edit documentation. Manual runs remain available. Website content uses
its separate deployment workflow; README-only edits also skip that workflow and
the image build workflow. These are native
[GitHub path filters](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#onpushpull_requestpull_request_targetpathspaths-ignore).

## Noodle Suite

**Assemble Noodle Suite** runs after a successful main release workflow or verified
artifact recovery. It can also be run manually on `main`. It packages the latest
published stable Noodle, Computer, and Applet releases; Browser joins after its
first stable release. Drafts, prereleases, and unreleased working-tree versions
are excluded. Suite requires macOS 26 and Apple silicon.

App release builds remain version-driven: a Computer patch builds Computer, while
Suite reuses the other published app bundles. Suite never invokes an app compiler,
changes app versions, or re-signs app bundles. Existing regression tests still run
for source changes, including shared integration coverage.

The planner downloads only small checksum and manifest files. Its fingerprint
includes the component tags, archive checksums, and DMG packaging recipe. Unchanged
inputs skip the macOS packaging job entirely. A previous complete Suite snapshot
is reused when channel promotion needs retrying. Published app ZIPs are cached by
SHA-256 and checked before reuse; a corrupt cache entry is downloaded again.
Only the current component archives are retained in each cache snapshot.

New Suites reuse the notarized apps after checking their checksums, production
identities, versions, architecture, updater feeds, and common signing team. The
outer DMG is signed and notarized separately. Packaging does not substitute for
the component release tests or establish compatibility across breaking protocol
changes; maintain the apps' integration contracts when releasing companions.

Each immutable `suite-<fingerprint>` release contains `Noodle-Suite-arm64.dmg`, its
checksum, and `suite-manifest.json` recording the exact inputs. The mutable
`suite-latest` channel copies the latest verified snapshot. Every Suite release
uses `--latest=false`, preserving Noodle's repository-wide latest release and
updater feed. Installed apps continue updating through their own feeds.

If a newer app releases during assembly, the older combination does not promote
over it; the queued Suite run resolves the newer releases. A failed Suite does
not roll back a successful app release. Rerun **Assemble Noodle Suite** to retry.
Incomplete immutable drafts require restoring the missing files from the saved
`suite-release-assets` workflow artifact before retrying; never rebuild an image
to overwrite an existing snapshot. Artifacts are retained for seven days.

For a local layout preview, put the signed production-named bundles into one
directory and run:

```sh
zsh scripts/package-dmg.sh --preview --suite .build/suite-apps .build/Noodle-Suite-preview.dmg
```

Suite uses a 900 × 560 window with the same 160-point icons as individual installers.
Select the apps and drag them to Applications. No installation helper is needed.

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
procedure so existing installations can still update. The apps must use the same
signing team for companion integration. Downloads must be public; the apps contain
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

## Update milestones

`Support/update-milestones.json` declares releases that users must run before
installing their successors. Use one when a release migrates or cleans up data that
later versions will no longer handle. Keep published versions intact.

Release packaging verifies the signed feeds of earlier milestones, preserves
their signed archive entries and immutable URLs, adds Sparkle's
`minimumUpdateVersion` to the new release, and signs the assembled feed. Older
installations therefore receive the required milestone first; ordinary patch
releases can still be skipped. Noodle enables update checks only after storage
loads successfully, so a milestone finishes its work before the next update is
offered. Keep milestone assets publicly available.

Code that only a milestone needs carries a `TODO(VERSION)` naming the release that
may delete it, with its call site and tests. Before deleting it, verify that the
enforced upgrade chain runs the milestone. Where skipping it could damage data, keep
a startup check with a clear error naming the release to run first. Manual app
downloads and clients predating Sparkle 2.9 can bypass feed prerequisites.

Add milestones in ascending order rather than requiring every minor release.
Changing a milestone version before its first publication must update the policy
file and the `TODO(VERSION)` comments that depend on it.

[Documentation](README.md)
