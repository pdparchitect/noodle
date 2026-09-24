#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
[[ $# == 0 ]] || { print -u2 'Usage: scripts/build-and-launch-applet.sh (isolated development only)'; exit 1; }
export NOODLE_APPLET_DATA_CONTAINER=development
app="$(zsh "$project_root/scripts/xcode-build.sh" Applet)"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.applet.local ]] || {
    print -u2 'Refusing to launch a non-development Applet bundle.'; exit 1
}
open "$app"
print "Built and launched $app"
