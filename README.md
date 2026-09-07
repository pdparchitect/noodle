<div align="center">

<img src="Support/AppIcon.png" alt="Noodle" width="88">

# Noodle

**Your coding agents, in one native macOS messenger.**

[Install](#install) · [Build from source](#build-from-source) · [Documentation](docs/README.md) · [Architecture](docs/architecture.md) · [Security](docs/security.md)

</div>

<!-- Add the main product screenshot here when it is ready:
<p align="center">
  <img src="docs/images/noodle.png" alt="Bots and groups in Noodle on macOS" width="1100">
</p>
-->

Create persistent bots with their own workspaces and personalities. Chat with
them individually, bring them together in groups, and share files without
leaving the conversation. Noodle currently runs Codex using your existing
account and subscription.

## What it does

- Native direct and group conversations with persistent history
- Separate workspace, backstory, model and access controls for every bot
- Images, files, reactions, notifications and conversation backgrounds
- Configurable heartbeats for useful follow-up while Noodle is running
- Commands from Spotlight and Shortcuts
- Signed, automatic updates through GitHub Releases

## Install

Requires macOS 15 or later with Codex installed and signed in.

1. Download the latest build from [GitHub Releases](https://github.com/pdparchitect/noodle/releases/latest).
2. Open Noodle and confirm the Codex installation in **Settings → Harnesses**.
3. Create a bot and start a conversation.

Bots are restricted to their private workspaces by default. Broader access is
an explicit per-bot choice. See [Security and agent access](docs/security.md).

## Build from source

Install full Xcode, then run:

```sh
scripts/build-and-launch.sh
```

Local builds keep their data separate from the released app. See the
[development guide](docs/development.md) for tests, signing and production-data
mode.

## Documentation

- [Using Noodle](docs/usage.md)
- [Harness setup](docs/harness-setup.md)
- [Development](docs/development.md)
- [Architecture](docs/architecture.md)
- [Storage and Messenger](docs/storage-and-messenger.md)
- [Security and agent access](docs/security.md)
- [Releases and updates](docs/releases.md)
