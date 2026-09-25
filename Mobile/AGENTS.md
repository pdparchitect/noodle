# Noodle Mobile

Keep the iPhone and iPad app in this folder. It joins a Noodle Hub and chats with the
bots its user keeps there, using the shared `HubLink` package the Mac apps use; change
pairing and the protocol there, not here. The phone lends no tools. Keep its release notes in
CHANGELOG.md here. Do not publish releases without the user's explicit request.

The app is built from an Xcode project that Tuist generates from `Project.swift`; the
generated project and `Derived/` are not committed. Describe targets and settings in
`Project.swift`, never by editing the generated project. The home screen shows "Noodle"
(or "Noodle Dev" for Debug) from `CFBundleDisplayName`; the bundle itself stays
`NoodleMobile`, which the test host relies on.

`scripts/mobile.sh` tests the app on an iPhone simulator, packages it and uploads it. A
release is a TestFlight build: dating a version section in CHANGELOG.md releases
`VERSION` through the same pipeline as the other apps, and `publish-mobile` uploads it.

README.md is for people using the app; do not document code in it. Follow the
`no-code-docs` skill.
