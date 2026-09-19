#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Applet app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.noodle.applet || "$bundle" == com.pdparchitect.noodle.applet.local ]]
codesign --verify --deep --strict "$app"
cmp "$project_root/Applet/Support/AppSymbol.svg" "$app/Contents/Resources/AppSymbol.svg"
zsh "$project_root/scripts/verify-updater.sh" "$app"
entitlements="$(mktemp /tmp/applet-entitlements.XXXXXX)"
preview_entitlements="$(mktemp /tmp/applet-preview-entitlements.XXXXXX)"
host_entitlements="$(mktemp /tmp/applet-host-entitlements.XXXXXX)"
trap 'rm -f "$entitlements" "$preview_entitlements" "$host_entitlements"' EXIT
noodlet_host="$app/Contents/XPCServices/NoodletHost.xpc"
codesign --verify --strict "$noodlet_host"
codesign -d --entitlements :- "$noodlet_host" > "$host_entitlements" 2>/dev/null
[[ "$(codesign -dv "$noodlet_host" 2>&1 | awk -F= '/^Identifier=/ {print $2}')" == "$bundle.noodlet-host" ]]
preview="$app/Contents/PlugIns/NoodletPreview.appex"
codesign --verify --strict "$preview"
codesign -d --entitlements :- "$preview" > "$preview_entitlements" 2>/dev/null
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
swift "$project_root/Applet/Tests/VerifyRelease.swift" "$info" "$entitlements" "$project_root/Applet/VERSION" "$preview/Contents/Info.plist" "$preview_entitlements" "$noodlet_host/Contents/Info.plist" "$host_entitlements"
