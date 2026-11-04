# Noodle Terminal

A terminal app for macOS that pairs with a Noodle Hub and lets people chat with the
bots and groups they keep there, like Noodle Mobile on an iPad. It is a thin client: the
Hub keeps everything and this app keeps only its pairing. It reaches the Hub through
`Shared/HubLink`; change the link and its protocol there, not here. No Hub changes are
made for this app.

It runs on macOS only. The UI is built with SwiftTUI, which needs Swift 6.4.

Terminal is versioned on its own from `VERSION` and `CHANGELOG.md` in this folder. It
has no release yet. Do not publish releases without the user's explicit request.

README.md is for people using the app; do not document code in it. Follow the
`no-code-docs` skill.
