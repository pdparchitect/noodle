# Changelog

## [Unreleased]

## [0.1.0] - 2026-11-11

### Added

- `sudo noodled setup` sets up a server step by step: it checks the machine and offers to install bubblewrap, msquic, Claude Code and Codex, asks a few questions, writes the configuration or keeps the one there, installs the service, signs in, starts the server and prints an invitation for your first device.
- Noodle Server, `noodled`: a Noodle Hub for Linux, set up in one file, that runs bots for the people you list on the Claude Code and Codex you install, each bot in a sandbox of its own.
- Plans say which harnesses, profiles and models people may use and how many tokens; users are listed by name with their plan.
- `noodled invite <user>` prints a link that pairs one device, and with `--qr` or `--png` its QR code too.
- `noodled login claude-code` and `noodled login codex` sign the server in with the harness's own sign-in, for a harness or one of its profiles; `noodled check` lists the logins nobody has signed in to yet.
- Download for Linux on arm64 and x86_64, with a systemd service.
