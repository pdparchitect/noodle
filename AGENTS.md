# Project instructions

## Message and event documentation

Keep message/event guidance in `Sources/NoodleCore/MessengerDocumentation.swift`. Runtime enums, group notices, and CLI dispatch use the catalogue; new cases must include handling guidance, recipients, and relevant payload fields or command usage. Agent runtime instructions, the Messenger skill, and CLI help are generated from this source.

After changing the catalogue or messaging contract, run `swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md` and include the generated reference in the same change. Do not edit that reference by hand. Builds and tests check for drift; update encoding-coverage tests when payload fields change.

## Release notes

Keep `CHANGELOG.md` current as part of every user-visible change. Add a concise entry under the appropriate heading in **Unreleased** in the same change; do not wait for release preparation to reconstruct it later.

When the user asks to mint or publish a version, follow the complete process in [`docs/releases.md`](docs/releases.md). Move the relevant Unreleased notes into the dated version section, keep any remaining work under Unreleased, and use the changelog entry as the release description. Do not publish a release unless the user explicitly asks.
