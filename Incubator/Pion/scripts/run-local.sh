#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Builds Pion (Release) from this checkout and runs it in place of the installed Pion, on the same data:
# the running Pion quits first, and the build opens from the repository's .build. Its updater stays off,
# so a published release never replaces it. Further arguments are build settings, as for build.sh.
set -euo pipefail
pion_root="${0:A:h:h}"
bundle_id="com.pdparchitect.pion"
app="$(PION_DATA_CONTAINER=production zsh "$pion_root/scripts/build.sh" "$@")"
if [[ -n "$(lsappinfo find bundleid="$bundle_id")" ]]; then
    osascript -e "tell application id \"$bundle_id\" to quit"
    for _ in {1..100}; do
        [[ -z "$(lsappinfo find bundleid="$bundle_id")" ]] && break
        sleep 0.1
    done
    [[ -z "$(lsappinfo find bundleid="$bundle_id")" ]] || { print -u2 "Pion is still running; quit it and run this again."; exit 1; }
fi
open "$app" --args -SUEnableAutomaticChecks NO -SUAutomaticallyUpdate NO
print "$app"
