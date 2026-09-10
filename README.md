<div align="center">

<img src="Support/AppIcon.png" alt="Noodle" width="88">

# Noodle

**Your coding agents, in one native macOS messenger.**

[Download](#download) · [Documentation](docs/README.md) · [Security](docs/security.md)

</div>

<p align="center">
  <img width="1490" alt="image" src="https://github.com/user-attachments/assets/0de27633-37f4-41d5-91fe-f16774d217dd" />
</p>

Create persistent bots with their own workspaces and personalities. Chat with
them individually, bring them together in groups, and share files without
leaving the conversation. Noodle runs Codex, Claude Code, FX, Grok Build, or Muse Code using your existing
account and subscription.

## Download

- **[Download Noodle](https://github.com/pdparchitect/noodle/releases/latest)** — the native messenger for your coding agents. Requires macOS 15 or later.
- **[Download Noodle Computer](https://github.com/pdparchitect/noodle/releases/tag/computer-latest)** — Linux desktops and terminals for you and your agents. Requires macOS 26 or later and Apple silicon.

Noodle Computer is optional and can also be used on its own.

## What it does

- Native direct and group conversations with persistent history
- Separate workspace, backstory, model and access controls for every bot
- Images, files, reactions, notifications and conversation backgrounds
- Configurable heartbeats that preserve true agent idleness across relaunches
- Commands from Spotlight and Shortcuts
- Signed, automatic updates through GitHub Releases

## Getting started

### Noodle

Requires macOS 15 or later with Codex, Claude Code, FX, Grok Build, or Muse Code installed and signed in.

1. Download the latest build from [GitHub Releases](https://github.com/pdparchitect/noodle/releases/latest).
2. Open Noodle and confirm your harness in **Settings → Harness**.
3. Create a bot and start a conversation.

New bots start restricted. Claude Code, FX, Grok Build, and Muse Code require the per-bot autonomous
access option in Settings → Security. See [Security and agent access](docs/security.md).

### Noodle Computer

Requires an Apple silicon Mac running macOS 26 or later. You do not need Xcode or Docker Desktop.

1. Download the latest build from [Noodle Computer releases](https://github.com/pdparchitect/noodle/releases/tag/computer-latest).
2. Open Noodle Computer and create a **Shell** or **Desktop** computer.
3. To share it with an agent, add it in the **Computers** tab when creating or editing a bot in Noodle.

A computer can be shared with multiple agents. Noodle discovers the installed app
automatically; you do not need to keep a Computer window open.
See the [Noodle Computer documentation](Computer/README.md) for more.

## Documentation

- [Noodle Computer — Linux desktops and terminals for you and your agents](Computer/README.md)
- [Using Noodle](docs/usage.md)
- [Harness setup](docs/harness-setup.md)
- [Development](docs/development.md)
- [Architecture](docs/architecture.md)
- [Storage and Messenger](docs/storage-and-messenger.md)
- [Security and agent access](docs/security.md)
- [Changelog](CHANGELOG.md)
- [Releases and updates](docs/releases.md)
