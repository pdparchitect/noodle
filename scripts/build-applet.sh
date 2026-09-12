#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
package="$project_root/Applet"
build_root="$project_root/.build/applet"
configuration="${NOODLE_APPLET_CONFIGURATION:-release}"
version="$(tr -d '[:space:]' < "$package/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Applet/VERSION'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$configuration" != release ]]; then
    print -u2 'Public releases require the optimized Applet build.'; exit 1
fi
swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" >&2
bin_path="$(swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
swiftc -typecheck -parse-as-library -swift-version 5 -module-cache-path "$build_root/RuntimeCheckCache" \
    "$package/Sources/NoodleApplet/Resources/NoodletRuntime.swift" \
    "$package/Sources/NoodleApplet/Resources/Examples/Orbit.noodlet/Orbit.swift"
staging="$(mktemp -d "$build_root/App.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Noodle Applet.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin_path/NoodleApplet" "$app/Contents/MacOS/"
cp "$bin_path/noodlet" "$app/Contents/Helpers/"
preview="$app/Contents/PlugIns/NoodletPreview.appex"
mkdir -p "$preview/Contents/MacOS"
cp "$bin_path/NoodletPreview" "$preview/Contents/MacOS/"
cp "$package/Support/Preview-Info.plist" "$preview/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$preview/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$preview/Contents/Info.plist"
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
for executable in "$app/Contents/MacOS/NoodleApplet" "$app/Contents/Helpers/noodlet" "$preview/Contents/MacOS/NoodletPreview"; do
    otool -l "$executable" | awk '/cmd LC_RPATH/ {found=1;next} found && /path / {print $2;found=0}' |
        while IFS= read -r rpath; do
            if [[ "$rpath" == "$bin_path" || "$rpath" == "$toolchain/"* ]]; then install_name_tool -delete_rpath "$rpath" "$executable"; fi
        done
done
cp -R "$bin_path/NoodleApplet_NoodleApplet.bundle" "$app/Contents/Resources/"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$sparkle"
# The app already has outbound network access, matching Computer's Sparkle setup.
rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
cp "$build_root/checkouts/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/NoodleApplet"
cp "$package/Support/Info.plist" "$app/Contents/Info.plist"
swift run --disable-sandbox --package-path "$project_root" NoodleDocumentation --write-applet-help "$app/Contents/Resources/NoodletCLIHelp.txt" >&2
updates_enabled=false
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then updates_enabled=true; fi
/usr/libexec/PlistBuddy -c "Add :NoodleUpdatesEnabled bool $updates_enabled" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
swift "$package/Support/MakeIcon.swift" "$staging/Applet.iconset" "$package/Support/AppIcon.png"
iconutil -c icns "$staging/Applet.iconset" -o "$app/Contents/Resources/Applet.icns"
identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"; fi
if [[ -z "$identity" ]]; then identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"; fi
[[ -n "$identity" && "$identity" != - ]] || { print -u2 'An Apple Development or Developer ID signing identity is required.'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$identity" != Developer\ ID\ Application:* ]]; then
    print -u2 'Public releases require a Developer ID Application identity.'; exit 1
fi
timestamp_option="--timestamp=none"
if [[ "${NOODLE_CODESIGN_TIMESTAMP:-0}" == 1 ]]; then timestamp_option="--timestamp"; fi
codesign --force --options runtime "$timestamp_option" --sign "$identity" --identifier com.pdparchitect.noodle.applet.cli "$app/Contents/Helpers/noodlet"
team="$(codesign -dv --verbose=4 "$app/Contents/Helpers/noodlet" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Signing identity has no team identifier.'; exit 1; }
group="$team.com.pdparchitect.noodle.applets"
/usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NoodleAppletGroup string $group" "$app/Contents/Info.plist"
cp "$package/Support/Applet.entitlements" "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$staging/entitlements.plist"
# Same two narrowly scoped Sparkle installer endpoints as Noodle and Computer.
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string com.pdparchitect.noodle.applet-spks' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string com.pdparchitect.noodle.applet-spki' "$staging/entitlements.plist"
cp "$package/Support/Preview.entitlements" "$staging/preview-entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$staging/preview-entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$staging/preview-entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :NoodleAppletGroup string $group" "$preview/Contents/Info.plist"
codesign --force --options runtime "$timestamp_option" --sign "$identity" --entitlements "$staging/preview-entitlements.plist" "$preview"
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "$timestamp_option" --sign "$identity" "$component"
done
codesign --force --options runtime "$timestamp_option" --sign "$identity" --entitlements "$staging/entitlements.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
zsh "$project_root/scripts/verify-applet-release.sh" "$app" >&2
destination="$project_root/.build/Noodle Applet.app"
if [[ -d "$destination" ]]; then rm -rf "$destination"; fi
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
print "$destination"
