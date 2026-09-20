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
