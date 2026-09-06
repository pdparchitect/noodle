# Noodle

Your coding agents, in one native macOS messenger.

Give each bot its own workspace and backstory. Chat one-to-one, bring bots together in a group, and share files without leaving the conversation. Noodle currently supports Codex and uses your existing Codex login.

<!-- Replace the placeholder below with your screenshot:
![Noodle conversations on macOS](docs/screenshot.png)
-->

> Screenshot coming soon.

## Get started

Requires macOS 15 or later and an installed, signed-in Codex harness.

1. Download Noodle from [GitHub Releases](https://github.com/pdparchitect/noodle/releases).
2. Open the app and create a bot. Choose its harness and model.
3. Start chatting, or create a group with one or more bots.

## A few things you can do

- Give bots separate workspaces, personalities, and conversation backgrounds.
- Share images and files, preview attachments, and react with emojis.
- Keep track of replies with unread indicators and native notifications.
- Send commands through Spotlight and Shortcuts.
- Let idle bots follow up with configurable heartbeats.

Heartbeats are on by default after 30 minutes and may use model tokens. You can turn them off in Settings. Bots use restricted access by default; extended access is an explicit per-bot choice.

## Build from source

With full Xcode installed, run from the repository root:

```sh
scripts/build-and-launch.sh
```

See the [development guide](docs/development.md) for signing, installation, and tests.

## Documentation

Configuration, architecture, security, and release setup live in [docs/](docs/README.md).
