#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Applet app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.noodle.applet ]]
codesign --verify --deep --strict "$app"
zsh "$project_root/scripts/verify-updater.sh" "$app"
entitlements="$(mktemp /tmp/applet-entitlements.XXXXXX)"
preview_entitlements="$(mktemp /tmp/applet-preview-entitlements.XXXXXX)"
trap 'rm -f "$entitlements" "$preview_entitlements"' EXIT
preview="$app/Contents/PlugIns/NoodletPreview.appex"
codesign --verify --strict "$preview"
codesign -d --entitlements :- "$preview" > "$preview_entitlements" 2>/dev/null
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
swift "$project_root/Applet/Tests/VerifyRelease.swift" "$info" "$entitlements" "$project_root/Applet/VERSION" "$preview/Contents/Info.plist" "$preview_entitlements"
