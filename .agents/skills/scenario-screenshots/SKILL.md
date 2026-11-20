---
name: scenario-screenshots
description: How to photograph a scenario, and how to make README screenshots over an app's own artwork, for Noodle, Pion or Rook. Use when taking, retaking or adding README screenshots, or photographing any scenario to check how it looks.
---

# Scenario screenshots

Any scenario can be photographed: `scenario.sh --shots SCENARIO` (Noodle's in `scripts/`, Pion's and Rook's in
`Incubator/APP/scripts/`) takes the window at each `capture` step of the scenario's timeline, into
`Scenarios/SCENARIO/shots/`, which git ignores.

For README images, photograph it over the app's artwork instead:

```sh
zsh scripts/readme-shots.sh Pion suspicious-sign-in 02-case=hero@1722
```

- It blurs the app's `Support/ReadmeArt.png` into a backdrop, takes the shots with `--background` and `--margin 0.16`,
  so the window's glass shows the picture through, then writes each `SHOT=IMAGE@WIDTH` to `.github/readme/IMAGE.png`
  with rounded corners. Without a `SHOT=IMAGE@WIDTH` it only takes the shots.
- `SHOT` is a `capture` name from the scenario. The hero goes at the capture's own width, about 1722; tiles at 1200.
- The terminal needs Screen Recording permission and the screen must stay unlocked, or the shots come out without the
  glass.
- Look at every image before committing them.

Pion's README set:

```sh
zsh scripts/readme-shots.sh Pion suspicious-sign-in 02-case=hero@1722
zsh scripts/readme-shots.sh Pion php2shell 01-tasks-and-pins=tasks@1200
zsh scripts/readme-shots.sh Pion week-overview 02-group=groups@1200
zsh scripts/readme-shots.sh Pion phishing-triage 03-audit=audit@1200
zsh scripts/readme-shots.sh Pion nothing-configured 01-empty=welcome@1200
```

## Another app

Commit its banner as `Support/ReadmeArt.png` in the app's folder; PNGs go through Git LFS. `scripts/readme-shots.sh`
already knows Noodle, Pion and Rook.
