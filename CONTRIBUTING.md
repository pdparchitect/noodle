# Contributing

Bug fixes, documentation improvements, and features are welcome.
Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Report an issue

Choose a bug report or feature request from the
[issue forms](https://github.com/pdparchitect/noodle/issues/new/choose).
Bug reports need app and macOS versions, steps to reproduce, and expected and
actual behavior. For agent problems, include the harness and its version.
For visual bugs, attach a screenshot of the current problem, or explain why you
cannot capture it; include an earlier working screenshot if available. Feature
requests should explain the problem and desired outcome, with current screenshots
and proposed mockups where relevant. Remove credentials and personal data from
logs and screenshots.

For substantial changes, open an issue first to discuss the approach.

## Make a change

1. Fork the repository and create a branch.
2. Read the [project instructions](AGENTS.md) and follow the build guide for [Noodle](docs/development.md) or [Noodle Computer](Computer/DEVELOPMENT.md).
3. Keep the change focused and run the relevant checks from the build guide. Keep documentation short and practical.
4. For user-visible changes, add a concise **Unreleased** note to the appropriate changelog: [Noodle](CHANGELOG.md), [Computer](Computer/CHANGELOG.md), or [images](Computer/Images/CHANGELOG.md).
5. Open a pull request explaining the problem, the change, and how you verified it. Link the related issue, if any, and follow the visual review requirements below.

## Visual changes

Pull requests that change the interface must include **before and after
screenshots** in the PR description before they are ready for review. This
includes layout, spacing, typography, colors, icons, and new screens in Noodle,
its companion apps, or the website.

- Capture the same scenario with matching window size, appearance, and sample
  content. Include enough surrounding interface to make the change understandable.
- Label the before screenshot with its version or commit; take the after
  screenshot from the PR build. Label relevant macOS versions and UI states.
- Show the states affected by the change, such as light/dark appearance,
  default/custom conversation backgrounds, or single-line/multiline input.
- For a new screen, show the previous workflow. If there is no prior equivalent,
  explain that under **Before**; an **After** screenshot is still required.
- Add a short recording for animation or interaction changes alongside the
  screenshots. Remove credentials and personal data from all captures.

For changes with no visual effect, select **No visual changes** in the PR template.
Maintainers should request missing visual evidence before approving a visual PR.

See [architecture](docs/architecture.md) for the runtime design and
[releases](docs/releases.md) for versioning and publishing.
