# Concurrent edits

Assume that multiple ai agents are editing this project. Don't get surprised.

# Project instructions

## Behaviour changes are test-first

Never change behaviour without a test that fails first. Follow the
`test-first-changes` skill in
[`.agents/skills/test-first-changes/SKILL.md`](.agents/skills/test-first-changes/SKILL.md).

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

Keep message/event guidance in `Sources/NoodleCore/MessengerDocumentation.swift` and never edit `docs/message-reference.md` by hand. When changing the catalogue or messaging contract, follow the
`update-message-catalogue` skill in
[`.agents/skills/update-message-catalogue/SKILL.md`](.agents/skills/update-message-catalogue/SKILL.md).

## Release notes

Keep `CHANGELOG.md` current as part of every user-visible change. Add a concise entry under the appropriate heading in **Unreleased** in the same change; do not wait for release preparation to reconstruct it later.

Do not publish a release unless the user explicitly asks. When the user asks to mint or publish a version, follow the
`mint-release` skill in
[`.agents/skills/mint-release/SKILL.md`](.agents/skills/mint-release/SKILL.md).
