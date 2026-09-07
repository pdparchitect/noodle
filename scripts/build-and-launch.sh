#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

case "${1:-}" in
    "") ;;
    --production-data) export NOODLE_DATA_CONTAINER=production ;;
    *)
        print -u2 "Usage: scripts/build-and-launch.sh [--production-data]"
        exit 1
        ;;
esac

if [[ "${NOODLE_DATA_CONTAINER:-development}" == "production" ]]; then
    if ! installed_app_running="$(osascript -e 'application "Noodle" is running' 2>/dev/null)"; then
        print -u2 "Could not verify whether the installed Noodle app is running; refusing to share production data."
        exit 1
    fi
    if [[ "$installed_app_running" == "true" ]]; then
        print -u2 "Quit the installed Noodle app before launching local code with production data."
        exit 1
    fi
fi

app="$("$project_root/scripts/build-app.sh")"
open "$app"
print "Built and launched $app"
