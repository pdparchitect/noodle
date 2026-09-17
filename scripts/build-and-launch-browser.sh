#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
[[ $# == 0 ]] || { print -u2 'Usage: scripts/build-and-launch-browser.sh (isolated development only)'; exit 1; }
export NOODLE_BROWSER_DATA_CONTAINER=development
unset NOODLE_BROWSER_APP_DESTINATION
app="$(zsh "$project_root/scripts/build-browser.sh")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.browser.local ]] || {
    print -u2 'Refusing to launch a non-development Browser bundle.'; exit 1
}
open "$app"
print "Built and launched $app"
