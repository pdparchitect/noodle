# Contributing

Bug fixes, documentation improvements, and features are welcome.

## Report an issue

Open an [issue](https://github.com/pdparchitect/noodle/issues) with your app and
macOS versions, steps to reproduce, and what you expected to happen. For agent
problems, include the harness and its version. Remove credentials and personal
data from logs and screenshots.

For substantial changes, open an issue first to discuss the approach.

## Make a change

1. Fork the repository and create a branch.
2. Read the [project instructions](AGENTS.md) and follow the build guide for [Noodle](docs/development.md) or [Noodle Computer](Computer/DEVELOPMENT.md).
3. Keep the change focused and run the relevant checks from the build guide. Keep documentation short and practical.
4. For user-visible changes, add a concise **Unreleased** note to the appropriate changelog: [Noodle](CHANGELOG.md), [Computer](Computer/CHANGELOG.md), or [images](Computer/Images/CHANGELOG.md).
5. Open a pull request explaining the problem, the change, and how you verified it. Include screenshots for interface changes.

See [architecture](docs/architecture.md) for the runtime design and
[releases](docs/releases.md) for versioning and publishing.
