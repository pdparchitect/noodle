#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
[[ $# == 0 ]] || { print -u2 'Usage: scripts/build-and-launch.sh (isolated development only)'; exit 1; }
# Launchers never accept production-data overrides, including inherited shell env.
export NOODLE_DATA_CONTAINER=development
app="$(zsh "$project_root/scripts/xcode-build.sh" Noodle)"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.local ]] || {
    print -u2 'Refusing to launch a non-development Noodle bundle.'; exit 1
}
open "$app"
print "Built and launched $app"
