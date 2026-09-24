#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
export NOODLE_DATA_CONTAINER=development
app="$(zsh "$project_root/scripts/xcode-build.sh" Noodle)"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.local ]] || {
    print -u2 'Refusing to install or launch a non-development Noodle bundle.'; exit 1
}
install_root="${NOODLE_INSTALL_DIR:-/Applications}"
installed_app="$install_root/${app:t}"

mkdir -p "$install_root"
if [[ -d "$installed_app" ]]; then
    rm -rf "$installed_app"
fi
ditto "$app" "$installed_app"
open "$installed_app"
print "Installed and launched $installed_app"
