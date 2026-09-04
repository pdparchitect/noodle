# SuperBot

SuperBot is a native macOS workspace for creating local bots and talking to them through a Messages-style interface. Each bot has a stable opaque identifier, a private folder in the application's Application Support directory, and a direct conversation. Bots can be renamed without moving their workspace. Two or more bots can also be invited into a shared group conversation.

This first stage deliberately stops at the local boundary: commands and transcripts are persisted, while harness routing remains visibly disconnected until the installed harness locations and invocation contracts are configured.

## Current capabilities

- Create and rename bots
- UUID-backed bot workspaces independent of display names
- Native macOS sidebar, search, selection, toolbar, and split-view resizing
- Direct bot conversations
- Multi-bot group conversations
- Durable local transcripts and queued commands
- Reveal a bot's workspace in Finder
- Clear harness connection state without fabricated replies

## Workspace layout

When sandboxed, macOS maps Application Support into SuperBot's private container. The logical structure is:

```text
Library/Application Support/SuperBot/
├── Agents/
│   └── <uuid>/
│       ├── agent.json
│       ├── instructions.md
│       └── memory.md
└── Conversations/
    └── <uuid>/
        ├── conversation.json
        └── messages.json
```

The folder key is never derived from the bot's display name.

## Build and launch

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
```

The signed application is written to `.build/SuperBot.app`. To install it in `/Applications`:

```sh
scripts/install-app.sh
```

Set `SUPERBOT_SIGNING_IDENTITY` to a signing identity when needed. The default is an ad-hoc local signature.

## Test

```sh
Tests/smoke-test.sh
```

The test suite verifies opaque workspace creation, rename stability, group persistence, transcript round-trips, the final app signature, App Sandbox entitlements, and dynamic-library linkage.

## Security boundary

SuperBot currently has only the App Sandbox entitlement. It has no network, user-selected file, automation, camera, microphone, contacts, or personal-data access. Harness integration will require an explicit design for discovering and invoking approved local executables without weakening this boundary.
