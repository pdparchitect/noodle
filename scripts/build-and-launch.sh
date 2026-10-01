#!/bin/zsh
# Builds an app's development identity and opens it: Noodle by default, or Computer, Applet, Browser or
# Hub. Development only; launchers never accept production-data overrides, including inherited ones.
# Computer Dev is installed first, where its Local Mac accounts can read it.
# --rehearse opens Noodle Dev as on a Mac with no bots and no harnesses, to try first-run setup with
# real downloads and sign-ins. Those stay in its own folder, emptied each time; your data is kept.
set -euo pipefail

project_root="${0:A:h:h}"
rehearse=false
if [[ "${1:-}" == --rehearse ]]; then rehearse=true; shift; fi
app_name="${1:-Noodle}"
case "$app_name" in
    Noodle) container_setting=NOODLE_DATA_CONTAINER; bundle=com.pdparchitect.noodle.local ;;
    Computer|Applet|Browser|Hub) container_setting="NOODLE_${(U)app_name}_DATA_CONTAINER"; bundle="com.pdparchitect.noodle.${(L)app_name}.local" ;;
    *) container_setting= ;;
esac
[[ -n "$container_setting" && $# -le 1 && ( "$rehearse" == false || "$app_name" == Noodle ) ]] || {
    print -u2 'Usage: scripts/build-and-launch.sh [--rehearse | Computer|Applet|Browser|Hub] (isolated development only)'; exit 1
}
# A copy already running would only come forward, still showing your own bots.
if [[ "$rehearse" == true ]] && pgrep -qf 'Noodle Dev.app/Contents/MacOS/'; then
    print -u2 'Quit Noodle Dev, then run this again.'; exit 1
fi
export "$container_setting=development"
app="$(zsh "$project_root/scripts/xcode-build.sh" "$app_name")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle" ]] || {
    print -u2 "Refusing to launch a non-development $app_name bundle."; exit 1
}
if [[ "$app_name" == Computer ]]; then app="$(python3 "$project_root/scripts/install-computer-dev.py" "$app")"; fi
if [[ "$rehearse" == true ]]; then
    # Set up afresh even if you chose Not Now in your own data, and open windows as on a first launch
    # rather than as your last session left them.
    open "$app" --args --rehearse -Noodle.firstBotSetup.dismissed NO -ApplePersistenceIgnoreState YES
else
    open "$app"
fi
# Started from a menu bar launcher, which is not the active app, macOS opens it behind the others.
osascript -e "tell application id \"$bundle\" to activate" >/dev/null 2>&1 || true
print "Built and launched $app"
