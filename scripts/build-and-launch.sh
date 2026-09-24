#!/bin/zsh
# Builds an app's development identity and opens it: Noodle by default, or Computer, Applet, Browser or
# Hub. Development only; launchers never accept production-data overrides, including inherited ones.
# Computer Dev is installed first, where its Local Mac accounts can read it.
set -euo pipefail

project_root="${0:A:h:h}"
app_name="${1:-Noodle}"
case "$app_name" in
    Noodle) container_setting=NOODLE_DATA_CONTAINER; bundle=com.pdparchitect.noodle.local ;;
    Computer|Applet|Browser|Hub) container_setting="NOODLE_${(U)app_name}_DATA_CONTAINER"; bundle="com.pdparchitect.noodle.${(L)app_name}.local" ;;
    *) container_setting= ;;
esac
[[ -n "$container_setting" && $# -le 1 ]] || {
    print -u2 'Usage: scripts/build-and-launch.sh [Computer|Applet|Browser|Hub] (isolated development only)'; exit 1
}
export "$container_setting=development"
app="$(zsh "$project_root/scripts/xcode-build.sh" "$app_name")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle" ]] || {
    print -u2 "Refusing to launch a non-development $app_name bundle."; exit 1
}
if [[ "$app_name" == Computer ]]; then app="$(python3 "$project_root/scripts/install-computer-dev.py" "$app")"; fi
open "$app"
print "Built and launched $app"
