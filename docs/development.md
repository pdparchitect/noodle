# Development

Run the commands below from the repository root.

## Build, launch, and test

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

The signed application is written to `.build/SuperBot.app`. To install it in `/Applications` and register its App Intent:

```sh
scripts/install-app.sh
```

The build automatically uses the first installed Apple Development identity so macOS can index App Intents. Set `SUPERBOT_SIGNING_IDENTITY` to override that choice, or set it to `-` explicitly for an ad-hoc build.

## Development-only Settings

Settings includes a Dev tab in debug builds only. The whole tab is compiled out of release builds. To build with development tools enabled:

```sh
SUPERBOT_BUILD_CONFIGURATION=debug scripts/build-app.sh
```

The Dev tab contains **Test Extended Runtime**, a fixed isolation-compatibility probe. It does not start a bot or prove browser access. See [Security and agent access](security.md) for the helper boundary and verification checks.

For distribution builds and GitHub Actions configuration, see [Releases and updates](releases.md).


---

[Documentation](README.md) · [SuperBot](../README.md)

