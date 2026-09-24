#!/bin/zsh
# The Xcode-built apps ship icons rendered from their Support/AppSymbol.svg. This renders them again and
# fails when a committed icon set no longer matches its symbol; --update rewrites the icon sets instead.
set -euo pipefail
project_root="${0:A:h:h}"
[[ $# == 0 || "$*" == --update ]] || { print -u2 'Usage: scripts/verify-icons.sh [--update]'; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/noodle-icons.XXXXXX")"
trap 'rm -rf "$work"' EXIT
for app icon in Applet AppletIcon Browser Browser Computer Computer Hub HubIcon; do
    committed="$project_root/$app/Support/Assets.xcassets/$icon.appiconset"
    zsh "$project_root/scripts/generate-icon.sh" "$project_root/$app/Support/AppSymbol.svg" "$work/$app.iconset" >&2
    if [[ "$*" == --update ]]; then
        cp "$work/$app.iconset"/*.png "$committed/"
        print "Updated $committed"
    else
        swift -module-cache-path "$project_root/.build/icon-generation/module-cache" \
            "$project_root/scripts/compare-icons.swift" "$work/$app.iconset" "$committed"
    fi
done
