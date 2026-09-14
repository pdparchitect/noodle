#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Computer app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.noodle.computer || "$bundle" == com.pdparchitect.noodle.computer.tests ]]
codesign --verify --deep --strict "$app"
zsh "$project_root/scripts/verify-updater.sh" "$app"
entitlements="$(mktemp /tmp/computer-entitlements.XXXXXX)"
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null
swift "$project_root/Computer/Tests/VerifyRelease.swift" "$info" "$entitlements" "$project_root/Computer/VERSION"
for kind in Preview Thumbnail; do
    extension="$app/Contents/PlugIns/Computer$kind.appex"
    codesign --verify --strict "$extension"
    codesign -d --entitlements :- "$extension" > "$entitlements" 2>/dev/null
    swift "$project_root/Computer/Tests/VerifyPreviewExtension.swift" "$extension/Contents/Info.plist" "$entitlements" "$info" "$kind"
done
