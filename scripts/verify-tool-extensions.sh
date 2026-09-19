#!/bin/zsh
set -euo pipefail
# Tool extensions run bot-supplied files through system frameworks. Each one must
# stay confined to the sandbox alone and bind to this build's extension point.
app="${1:?Pass the built Noodle.app path}"
extensions="$app/Contents/Extensions"
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
point="$bundle_identifier.tool"
[[ "$(/usr/libexec/PlistBuddy -c "Print :$point:EXExtensionPointName" "$extensions/Noodle.appexpt")" == tool ]] ||
    { print -u2 "Noodle.appexpt does not declare $point"; exit 1; }
found=0
for extension in "$extensions"/*.appex(N); do
    found=$((found + 1))
    codesign --verify --strict "$extension"
    details="$(codesign -dv --verbose=4 "$extension" 2>&1)"
    [[ "$(print -r -- "$details" | awk -F= '/^TeamIdentifier=/ { print $2 }')" == "$team" ]] ||
        { print -u2 "${extension:t} is not signed by the app's team"; exit 1; }
    print -r -- "$details" | grep -Eq '^CodeDirectory .*flags=.*runtime' ||
        { print -u2 "${extension:t} must use the hardened runtime"; exit 1; }
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extension/Contents/Info.plist")"
    [[ "$identifier" == "$bundle_identifier".* ]] || { print -u2 "${extension:t} must be named under $bundle_identifier"; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :EXAppExtensionAttributes:EXExtensionPointIdentifier' "$extension/Contents/Info.plist")" == "$point" ]] ||
        { print -u2 "${extension:t} does not bind to $point"; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSBackgroundOnly' "$extension/Contents/Info.plist")" == true ]] ||
        { print -u2 "${extension:t} must stay out of the Dock"; exit 1; }
    entitlements="$(codesign -d --entitlements :- "$extension" 2>/dev/null | tr -d '[:space:]')"
    [[ "$(print -r -- "$entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')" == 1 ]] ||
        { print -u2 "${extension:t} must have only the sandbox entitlement"; exit 1; }
    print -r -- "$entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>' ||
        { print -u2 "${extension:t} must be sandboxed"; exit 1; }
done
(( found > 0 )) || { print -u2 "No tool extensions were bundled"; exit 1; }
print "Tool extension point, signatures and sandbox-only entitlements verified ($found)"
