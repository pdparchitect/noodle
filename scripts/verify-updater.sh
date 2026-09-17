#!/bin/zsh
set -euo pipefail
if [[ "${NOODLE_VERIFY_VERBOSE:-0}" == 1 ]]; then set -x; fi
app="${1:?Pass the built Noodle.app path}"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
info="$app/Contents/Info.plist"
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
[[ ! -e "$sparkle/Versions/B/XPCServices/Downloader.xpc" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableInstallerLauncherService' "$info")" == true ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$info")" == true ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$info")" == true ]]
expected_feed='https://github.com/pdparchitect/noodle/releases/latest/download/appcast.xml'
case "$bundle_identifier" in
    com.pdparchitect.noodle.computer|com.pdparchitect.noodle.computer.local|com.pdparchitect.noodle.computer.tests)
        expected_feed='https://github.com/pdparchitect/noodle/releases/download/computer-latest/appcast.xml' ;;
    com.pdparchitect.noodle.applet|com.pdparchitect.noodle.applet.local)
        expected_feed='https://github.com/pdparchitect/noodle/releases/download/applet-latest/appcast.xml' ;;
esac
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info")" == "$expected_feed" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info")" == '1ZT5NrPiDPaQ54iHGSI1a9JIn6kTrmjQvzZRBA9f/sk=' ]]
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == "1" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :NoodleUpdatesEnabled' "$info")" == true ]]
fi
signed="$(codesign -d --entitlements :- "$app" 2>/dev/null | tr -d '[:space:]')"
# Consume full command output so pipefail cannot mistake grep's early exit for a verification failure.
print -r -- "$signed" | grep -F '<key>com.apple.security.app-sandbox</key><true/>' >/dev/null
print -r -- "$signed" | grep -F "<key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>$bundle_identifier-spks</string><string>$bundle_identifier-spki</string></array>" >/dev/null
for component in \
    "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app" \
    "$sparkle"; do
    codesign --verify --strict "$component"
    details="$(codesign -dv --verbose=4 "$component" 2>&1)"
    print -r -- "$details" | grep -F "TeamIdentifier=$team" >/dev/null
    print -r -- "$details" | grep 'flags=.*runtime' >/dev/null
    entitlements="$(codesign -d --entitlements :- "$component" 2>/dev/null)"
    if print -r -- "$entitlements" | grep '<key>' >/dev/null; then
        print -u2 "Unexpected entitlement in updater component: $component"; exit 1
    fi
done
binary="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"
otool -L "$binary" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null
rpaths="$(otool -l "$binary" | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }')"
print -r -- "$rpaths" | grep -Fx '@executable_path/../Frameworks' >/dev/null
if print -r -- "$rpaths" | grep '^/' | grep -Fvx '/usr/lib/swift' >/dev/null; then
    print -u2 "App contains an absolute framework search path: $rpaths"; exit 1
fi
test -s "$app/Contents/Resources/Sparkle-LICENSE.txt"
print 'Updater signatures, bundle-relative linking, signed feed, and sandbox policy verified'
