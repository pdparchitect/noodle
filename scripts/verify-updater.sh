#!/bin/zsh
set -euo pipefail
app="${1:?Pass the built Noodle.app path}"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
info="$app/Contents/Info.plist"
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
[[ ! -e "$sparkle/Versions/B/XPCServices/Downloader.xpc" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableInstallerLauncherService' "$info")" == true ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$info")" == true ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$info")" == true ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")" == 'https://github.com/pdparchitect/noodle/releases/latest/download/appcast.xml' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")" == '1ZT5NrPiDPaQ54iHGSI1a9JIn6kTrmjQvzZRBA9f/sk=' ]]
signed="$(codesign -d --entitlements :- "$app" 2>/dev/null | tr -d '[:space:]')"
print -r -- "$signed" | grep -Fq '<key>com.apple.security.app-sandbox</key><true/>'
print -r -- "$signed" | grep -Fq '<key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>com.pdparchitect.noodle-spks</string><string>com.pdparchitect.noodle-spki</string></array>'
for component in \
    "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app" \
    "$sparkle"; do
    codesign --verify --strict "$component"
    details="$(codesign -dv --verbose=4 "$component" 2>&1)"
    print -r -- "$details" | grep -Fq "TeamIdentifier=$team"
    print -r -- "$details" | grep -q 'flags=.*runtime'
    entitlements="$(codesign -d --entitlements :- "$component" 2>/dev/null)"
    if print -r -- "$entitlements" | grep -q '<key>'; then
        print -u2 "Unexpected entitlement in updater component: $component"; exit 1
    fi
done
binary="$app/Contents/MacOS/Noodle"
otool -L "$binary" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'
rpaths="$(otool -l "$binary" | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }')"
print -r -- "$rpaths" | grep -Fxq '@executable_path/../Frameworks'
if print -r -- "$rpaths" | grep '^/' | grep -Fvxq '/usr/lib/swift'; then
    print -u2 "App contains an absolute framework search path: $rpaths"; exit 1
fi
test -s "$app/Contents/Resources/Sparkle-LICENSE.txt"
print 'Updater signatures, bundle-relative linking, signed feed, and sandbox policy verified'
