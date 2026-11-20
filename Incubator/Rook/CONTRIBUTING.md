# Contributing

Bug fixes and features are welcome. Rook is incubating inside the
[Noodle repository](https://github.com/pdparchitect/noodle), so report issues and open pull
requests there, and follow its [Code of Conduct](../../CODE_OF_CONDUCT.md).

## Report an issue

Bug reports need the Rook and macOS versions, steps to reproduce, and expected and actual
behaviour. For agent problems, include the harness and its version, and for a tool, which
service. Remove credentials, hostnames and other personal or customer data from logs and
screenshots.

## Build and run

Run `scripts/build.sh` in this folder. It builds Rook Dev, which keeps its own agents,
conversations and sign-ins apart from an installed Rook, and puts it in the repository's
`.build` folder.

## Scenarios

`scripts/scenario.sh` opens Rook in a scenario from `Scenarios/`: a scripted team and
Missions in a separate copy of Rook Dev with no network and no access to your data.
Without a name it opens the picker. With a name, or from the picker, it opens in the
scenario's starting state and stays there for you to look around; only a capture plays its
timeline.

- `--shots` plays it and saves each captured step to the scenario's `shots` folder.
- `--video` records it to the scenario's `recordings` folder, with the film's titles, camera
  moves and sounds; `--ratio 16:9` and other shapes make MP4s.
- `--no-intro`, `--no-outro` and `--no-titles` leave out its opening card, closing card or both.
- `--background` with a file or web address records it over that picture or video, without
  writing it into the scenario.

## Make a change

1. Read the [project instructions](AGENTS.md).
2. Keep the change focused and run the relevant checks.
3. For user-visible changes, add a concise **Unreleased** note to the [changelog](CHANGELOG.md).
4. Changes to the interface need **before and after screenshots** in the pull request.

## License

By contributing, you agree that your contribution is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md), as the rest of Rook is.
