# Development

Run the commands below from the repository root.

## Build, launch, and test

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

The signed application is written to `.build/Noodle.app`. To install it in `/Applications` and register its App Intent:

```sh
scripts/install-app.sh
```

The build automatically uses the first installed Apple Development identity so macOS can index App Intents. Set `NOODLE_SIGNING_IDENTITY` to override that choice, or set it to `-` explicitly for an ad-hoc build.

## Development-only Settings

Settings includes a Dev tab in debug builds only. The whole tab is compiled out of release builds. To build with development tools enabled:

```sh
NOODLE_BUILD_CONFIGURATION=debug scripts/build-app.sh
```

The Dev tab contains **Test Extended Runtime**, a fixed isolation-compatibility probe. It does not start a bot or prove browser access. See [Security and agent access](security.md) for the helper boundary and verification checks.

To test the normal app with no detected harnesses, quit Noodle and launch a debug build with:

```sh
NOODLE_SIMULATE_NO_HARNESSES=1 .build/Noodle.app/Contents/MacOS/Noodle
```

This only overrides harness detection, including subsequent refreshes. It adds no UI and does not remove installed binaries, credentials, bots, or conversations. Relaunch without the variable to restore normal detection. The override is compiled out of release builds; they ignore the variable.

For distribution builds and GitHub Actions configuration, see [Releases and updates](releases.md).


---

[Documentation](README.md) · [Noodle](../README.md)
