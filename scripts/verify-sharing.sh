#!/bin/zsh
set -euo pipefail
app="${1:?Pass the built SuperBot.app path}"
extension="$app/Contents/PlugIns/SuperBotShare.appex"
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
expected="$team.com.pdparchitect.superbot.sharing"
for bundle in "$app" "$extension"; do
    codesign --verify --strict "$bundle"
    group="$(/usr/libexec/PlistBuddy -c 'Print :SuperBotSharedGroup' "$bundle/Contents/Info.plist")"
    [[ "$group" == "$expected" ]] || { print -u2 "Share group does not match the signing team"; exit 1; }
    signed="$(codesign -d --entitlements - "$bundle" 2>/dev/null)"
    print -r -- "$signed" | grep -Fq "$expected" || { print -u2 "Missing signed share-group entitlement"; exit 1; }
done
extension_entitlements="$(codesign -d --entitlements :- "$extension" 2>/dev/null | tr -d '[:space:]')"
count="$(print -r -- "$extension_entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
[[ "$count" == "2" ]] || { print -u2 "Share extension must have only sandbox and app-group entitlements"; exit 1; }
print -r -- "$extension_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>'
if otool -L "$extension/Contents/MacOS/SuperBotShareExtension" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "Share extension depends on a mutable external library"
    exit 1
fi
print "Sharing signature and sandbox checks passed"
