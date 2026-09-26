#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Computer app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.noodle.computer || "$bundle" == com.pdparchitect.noodle.computer.local || "$bundle" == com.pdparchitect.noodle.computer.tests ]]
codesign --verify --deep --strict "$app"
cmp "$project_root/Computer/Support/AppSymbol.svg" "$app/Contents/Resources/AppSymbol.svg"
zsh "$project_root/scripts/verify-updater.sh" "$app"
# Development and test bundles carry development launch checks; a production bundle must not.
if [[ "$bundle" == com.pdparchitect.noodle.computer ]]; then zsh "$project_root/scripts/verify-launch-hooks.sh" "$app"; fi
entitlements="$(mktemp /tmp/computer-entitlements.XXXXXX)"
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
swift "$project_root/Computer/Tests/VerifyRelease.swift" "$info" "$entitlements" "$project_root/Computer/VERSION"
# Computers are shared as links; the app ships no Quick Look extensions.
[[ ! -e "$app/Contents/PlugIns" ]] || [[ -z "$(ls "$app/Contents/PlugIns")" ]]
cmp "$project_root/Computer/Images/shared/noodle-welcome" "$app/Contents/Helpers/LocalMacDesktop.app/Contents/Resources/noodle-welcome"
service_path="${app:A}/Contents/Helpers/LocalMacSetup.app/Contents/Library/LaunchServices/LocalMacService"
"$service_path" --check-layout
(cd /; exec -a Contents/Library/LaunchServices/LocalMacService "$service_path" --check-layout)
for helper in "$app/Contents/Helpers/LocalMacSetup.app/Contents/Library/LaunchServices/LocalMacService" "$app/Contents/Helpers/LocalMacSetup.app" "$app/Contents/Helpers/LocalMacDesktop.app"; do
    codesign --verify --strict "$helper"
    codesign -d --entitlements :- "$helper" > "$entitlements" 2>/dev/null
    swift "$project_root/Computer/Tests/VerifyLocalMacHelper.swift" "$helper" "$entitlements"
done
