#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app="$("$project_root/scripts/build-app.sh")"
install_root="${SUPERBOT_INSTALL_DIR:-/Applications}"
installed_app="$install_root/SuperBot.app"

mkdir -p "$install_root"
if [[ -d "$installed_app" ]]; then
    rm -rf "$installed_app"
fi
ditto "$app" "$installed_app"
open "$installed_app"
print "Installed and launched $installed_app"
