# Noodle Hub

Keep the Hub application, its core and its tests in this folder. The Hub runs bots
with Noodle's own runtime (the `NoodleCore` and `NoodleRuntime` products of the root
package); change that code in the root package, not here. Keep Hub release notes in
CHANGELOG.md here and Noodle integration notes in the root changelog.
Do not publish releases without the user's explicit request.

The Hub lives in the menu bar only: `LSUIElement` in its bundle and the `.accessory`
activation policy. Its data stays apart from Noodle's, in its own container under
`Application Support/Noodle`: the Agent Host looks for bots in a folder with that name.

The app is built from an Xcode project that Tuist generates from `Project.swift`; the generated
project and `Derived/` are not committed. Describe targets, settings and embedding in
`Project.swift`, never by editing the generated project. Its two build phases embed and sign the
helpers and trim Sparkle; everything else is target settings. `scripts/verify-hub-release.sh`
checks the result against `Support/Hub.entitlements` and the Agent Host rules.

Settings reuse Noodle's Harness, Heartbeat, Sandbox, Tools and Companions views from
`NoodleRuntimeSettings` through `BotSettingsHost`; change them there, not here. The Hub
does not run bots yet, has no bot editor, and opens companions directly rather than
connecting to them.
