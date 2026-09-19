---
name: mint-release
description: Procedure for minting or publishing a version of Noodle, Computer, Applet, Browser or the Computer images. Use when the user asks to mint, cut, prepare, release or publish a version, bump a VERSION file, or turn Unreleased changelog notes into a dated release section.
---

# Mint a release

Do not publish a release unless the user explicitly asks. Pushing a new version
to `main` requests publication, so commit and push only on that explicit request.

The complete process, including the per-product version and changelog files, CI
behaviour and recovery, is in [`docs/releases.md`](../../../docs/releases.md).
Read it first and follow it; this skill only summarises the preparation.

## Prepare

1. Set the product's version file to an unused, higher `X.Y.Z`.
2. Move the relevant Unreleased notes in that product's changelog into
   `## [X.Y.Z] - YYYY-MM-DD`. Keep any remaining work under Unreleased.
3. Use that changelog entry as the release description.
4. Run the affected tests and review the changes.

Do not create tags manually or reuse published versions.
