# Development

Run the commands below from the repository root.

## Build, launch, and test

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

Local builds use the isolated development container by default and are written to `.build/Noodle Local.app`. This keeps test bots, conversations, preferences, and agent state separate from the released app. To install that development build in `/Applications` and register its App Intent:

```sh
scripts/install-app.sh
```

To test current local code against the released app's production data, first quit the installed Noodle app, then use the explicit production-data mode:

```sh
scripts/build-and-launch.sh --production-data
```

That mode writes `.build/Noodle.app` with the production bundle identity. Never run it at the same time as `/Applications/Noodle.app`; both processes would own the same conversations and agent state. Release packaging selects the production identity automatically.

The build automatically uses the first installed Apple Development identity so macOS can index App Intents. Set `NOODLE_SIGNING_IDENTITY` to override that choice, or set it to `-` explicitly for an ad-hoc build.

## Message documentation

Message and event guidance lives in `Sources/NoodleCore/MessengerDocumentation.swift`, alongside exhaustive references for runtime wake reasons, delivery kinds, group notices, effects and CLI commands. Agent workspace instructions and Messenger help use this catalogue directly; workspace synchronization refreshes the managed guidance while preserving each bot's backstory and custom skills.

After changing the catalogue, regenerate and commit the reference:

```sh
swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md
swift run --disable-sandbox NoodleDocumentation --check docs/message-reference.md
```

The application build checks the reference without rewriting it. Tests also check documentation freshness and encoded delivery/message field coverage. The generator runs locally and is not bundled into the app.

## Development-only Settings

Settings includes a Dev tab in debug builds only. The whole tab is compiled out of release builds. To build with development tools enabled:

```sh
NOODLE_BUILD_CONFIGURATION=debug scripts/build-app.sh
```

The Dev tab contains **Test Autonomous Runtime**, a fixed isolation-compatibility probe. It does not start a bot or prove browser access. See [Security and agent access](security.md) for the helper boundary and verification checks.

To test the normal app with no detected harnesses, quit Noodle and launch a debug build with:

```sh
NOODLE_SIMULATE_NO_HARNESSES=1 '.build/Noodle Local.app/Contents/MacOS/Noodle'
```

This only overrides harness detection, including subsequent refreshes. Check Installation enables external standalone/CLI detection for the current session; ChatGPT/Codex app-bundled binaries stay excluded. It adds no UI and does not remove installed binaries, credentials, bots, or conversations. Relaunch without the variable to restore normal detection. The override is compiled out of release builds; they ignore the variable.

For distribution builds and GitHub Actions configuration, see [Releases and updates](releases.md).


---

[Documentation](README.md) · [Noodle](../README.md)
