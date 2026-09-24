# Noodle Applet

Keep the companion application, runners, package handling, and CLI in this folder.
Integration compatibility uses the versioned Protocol package. Keep Applet release
notes in CHANGELOG.md here and Noodle integration notes in the root changelog.
Do not publish releases without the user's explicit request.

The guidance bots and people read for the `noodlet` command lives in
Protocol/Sources/AppletBridge/AppletGuidance.swift. Noodle writes it into each bot's
applet skill and the command prints it for --help; do not copy it anywhere else. Test package validation, single-instance ownership,
and runtime diagnostics. Verify the signed sandboxed bundle before claiming a
runtime or capability works.

The app is built from an Xcode project that Tuist generates from `Project.swift`; the generated
project and `Derived/` are not committed. Describe targets, settings and embedding there, never by
editing the generated project. Its build phases check the noodlet runtime compiles, embed and sign
the CLI, rename development examples and trim Sparkle; everything else is target settings.

Launch arguments for verification runs are matched by digest (`AppletLaunchCheck` in
Sources/NoodleApplet/App.swift, Shared/LaunchChecks), so no name appears in the binary.
One that the release workflow or RELEASING.md runs against the packaged app stays in every
build. Any other goes under `#if NOODLE_DEV_HOOKS`, which only development bundles and
debug builds compile. `scripts/verify-launch-hooks.sh` checks a production bundle.

README.md is for people using Applet; do not document code in it. Follow the
`no-code-docs` skill.
