#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Photographs a scenario for an app's README: the window over the app's artwork, blurred, its glass showing it through.
# scripts/readme-shots.sh APP SCENARIO [SHOT=IMAGE@WIDTH ...] takes the scenario's shots over APP's Support/ReadmeArt.png,
# then writes each SHOT named as IMAGE to APP's .github/readme/IMAGE.png, WIDTH pixels wide with rounded corners.
# APP is Noodle, Pion or Rook. The terminal needs Screen Recording permission, and the screen must stay unlocked.
set -euo pipefail
project_root="${0:A:h:h}"
usage() { print -u2 "Usage: scripts/readme-shots.sh Noodle|Pion|Rook SCENARIO [SHOT=IMAGE@WIDTH ...]"; exit 1; }
(( $# >= 2 )) || usage
app="$1" scenario="$2"
shift 2
case "$app" in
    Noodle) folder="$project_root" ;;
    Pion|Rook) folder="$project_root/Incubator/$app" ;;
    *) usage ;;
esac
art="$folder/Support/ReadmeArt.png"
[[ -f "$art" ]] || { print -u2 "There is no artwork at $art: commit $app's banner there first."; exit 1; }
for mapping in "$@"; do
    [[ "$mapping" == ?*=?*@<1-> ]] || { print -u2 "$mapping is not SHOT=IMAGE@WIDTH."; exit 1; }
done

tool="$project_root/scripts/readme-image.swift"
cache="$project_root/.build/readme"
mkdir -p "$cache/module-cache"
image() { swift -module-cache-path "$cache/module-cache" "$tool" "$@"; }
# Drawn once, and again only when the artwork or the tool changes.
backdrop="$cache/${(L)app}-backdrop.png"
[[ "$backdrop" -nt "$art" && "$backdrop" -nt "$tool" ]] || image backdrop "$art" "$backdrop"

zsh "$folder/scripts/scenario.sh" --shots --no-titles --margin 0.16 --background "$backdrop" "$scenario"

shots="$folder/Scenarios/$scenario/shots"
for mapping in "$@"; do
    shot="${mapping%%=*}" rest="${mapping#*=}"
    name="${rest%@*}" width="${rest##*@}"
    [[ -f "$shots/$shot.png" ]] || { print -u2 "$scenario took no shot called $shot."; exit 1; }
    out="$folder/.github/readme/$name.png"
    mkdir -p "${out:h}"
    image round "$shots/$shot.png" "$out" "$width"
    if command -v optipng >/dev/null; then optipng -quiet -o2 "$out"; fi
    print "$out"
done
