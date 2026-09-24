#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
[[ $# == 0 ]] || { print -u2 'Usage: scripts/build-and-launch-computer.sh (isolated development only)'; exit 1; }
export NOODLE_COMPUTER_DATA_CONTAINER=development
app="$(zsh "$project_root/scripts/xcode-build.sh" Computer)"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.computer.local ]] || {
    print -u2 'Refusing to launch a non-development Computer bundle.'; exit 1
}
app="$(python3 "$project_root/scripts/install-computer-dev.py" "$app")"
open "$app"
print "Built, installed and launched $app"
