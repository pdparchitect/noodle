# Noodle Applet

Keep the companion application, runners, package handling, and CLI in this folder.
Integration compatibility uses the versioned Protocol package. Keep Applet release
notes in CHANGELOG.md here and Noodle integration notes in the root changelog.
Do not publish releases without the user's explicit request.

Agent-facing command and message guidance is catalogued in
../Sources/NoodleCore/MessengerDocumentation.swift; regenerate the root message
reference when changing it. Test package validation, single-instance ownership,
and runtime diagnostics. Verify the signed sandboxed bundle before claiming a
runtime or capability works.
