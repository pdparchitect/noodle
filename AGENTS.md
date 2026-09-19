# Concurrent edits

Assume that multiple ai agents are editing this project. Don't get surprised.

# Project instructions

## Behaviour changes are test-first

Do not change behaviour on the strength of reading the code. First write a test
that exercises the specific code and fails because of the problem, and run it to
see it fail. Then make the change and run the same test to see it pass. Report
both runs. A suspected cause that no test can reproduce is still a hypothesis;
say so instead of changing code. Tests must not depend on a harness account, a
model, the network or timing, so that they also pass in CI.

## UI copy

Keep visible copy focused on functional labels and necessary status or error messages.
Do not add persistent instructional hints, shortcut legends, or explanatory footer
text unless explicitly requested. Put optional guidance in tooltips or documentation.

## Helper visibility

Helpers and standalone development/test fixtures must stay out of the Dock and
app switcher by default. Set `LSUIElement` for helper app bundles and use AppKit's
`.accessory` activation policy when they need windows; use `LSBackgroundOnly` for
background-only executable metadata. Do not promote helpers to `.regular`.
The main Noodle, Noodle Computer, and Noodle Applet apps retain their Dock entries.

## Apple history utilities

When changing Apple context management or upgrading the Apple SDK/toolchain, read
[`Sources/NoodleAppleRuntime/FoundationModelsUtilities/AGENTS.md`](Sources/NoodleAppleRuntime/FoundationModelsUtilities/AGENTS.md)
and check the copied Apple utilities for upstream updates.

## Message and event documentation

Keep message/event guidance in `Sources/NoodleCore/MessengerDocumentation.swift`. Runtime enums, group notices, and CLI dispatch use the catalogue; new cases must include handling guidance, recipients, and relevant payload fields or command usage. Agent runtime instructions, the Messenger skill, and CLI help are generated from this source.

After changing the catalogue or messaging contract, run `swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md` and include the generated reference in the same change. Do not edit that reference by hand. Builds and tests check for drift; update encoding-coverage tests when payload fields change.

## Release notes

Keep `CHANGELOG.md` current as part of every user-visible change. Add a concise entry under the appropriate heading in **Unreleased** in the same change; do not wait for release preparation to reconstruct it later.

When the user asks to mint or publish a version, follow the complete process in [`docs/releases.md`](docs/releases.md). Move the relevant Unreleased notes into the dated version section, keep any remaining work under Unreleased, and use the changelog entry as the release description. Do not publish a release unless the user explicitly asks.
