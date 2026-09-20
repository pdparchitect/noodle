#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
if [[ "${1:-}" == --both && $# == 1 ]]; then
    [[ -z "${NOODLE_BROWSER_APP_DESTINATION:-}" ]] || { print -u2 'Use separate default destinations with --both.'; exit 1; }
    NOODLE_BROWSER_DATA_CONTAINER=development zsh "$0"
    NOODLE_BROWSER_DATA_CONTAINER=production zsh "$0"
    exit 0
fi
[[ $# == 0 ]] || { print -u2 'Usage: build-browser.sh [--both]'; exit 1; }
package="$project_root/Browser"
build_root="${NOODLE_BROWSER_BUILD_ROOT:-$project_root/.build/browser}"
configuration="${NOODLE_BROWSER_CONFIGURATION:-release}"
data_container="${NOODLE_BROWSER_DATA_CONTAINER:-${NOODLE_DATA_CONTAINER:-development}}"
case "$data_container" in
    development) bundle_identifier="com.pdparchitect.noodle.browser.local"; app_name="Noodle Browser Dev"; group_suffix="com.pdparchitect.noodle.browsers.local"; scheme="noodlebrowser-dev" ;;
    production) bundle_identifier="com.pdparchitect.noodle.browser"; app_name="Noodle Browser"; group_suffix="com.pdparchitect.noodle.browsers"; scheme="noodlebrowser" ;;
    *) print -u2 'NOODLE_BROWSER_DATA_CONTAINER must be development or production.'; exit 1 ;;
esac
# Browser/Package.swift reads this. A development bundle keeps its development hooks;
# a production bundle never has them, whatever the calling shell exports.
if [[ "$data_container" == development ]]; then export NOODLE_DEV_HOOKS=1; else unset NOODLE_DEV_HOOKS; fi
version="$(tr -d '[:space:]' < "$package/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Browser/VERSION'; exit 1; }
mkdir -p "$build_root/module-cache"
export CLANG_MODULE_CACHE_PATH="$build_root/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_root/module-cache"
swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" >&2
bin_path="$(swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
staging="$(mktemp -d "$build_root/App.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/$app_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/NoodleBrowser" "$app/Contents/MacOS/"
cp -R "$bin_path/NoodleBrowser_NoodleBrowser.bundle" "$app/Contents/Resources/"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$sparkle"
# Match Computer and Applet: the host already has outbound networking.
rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
cp "$build_root/checkouts/Sparkle/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/NoodleBrowser"
cp "$package/Support/Info.plist" "$app/Contents/Info.plist"
updates_enabled=false
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then updates_enabled=true; fi
/usr/libexec/PlistBuddy -c "Add :NoodleUpdatesEnabled bool $updates_enabled" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $bundle_identifier.link" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $scheme" "$app/Contents/Info.plist"
reference_type="com.pdparchitect.noodle.browser-reference"
if [[ "$data_container" == development ]]; then reference_type="$reference_type.dev"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleDocumentTypes:0:LSItemContentTypes:0 $reference_type" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :UTExportedTypeDeclarations:0:UTTypeIdentifier $reference_type" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 $scheme" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
zsh "$project_root/scripts/generate-icon.sh" "$package/Support/AppSymbol.svg" "$staging/Browser.iconset" >&2
iconutil -c icns "$staging/Browser.iconset" -o "$app/Contents/Resources/Browser.icns"
cp "$package/Support/AppSymbol.svg" "$app/Contents/Resources/AppSymbol.svg"
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
otool -l "$app/Contents/MacOS/NoodleBrowser" | awk '/cmd LC_RPATH/ {found=1;next} found && /path / {print $2;found=0}' |
    while IFS= read -r rpath; do
        if [[ "$rpath" == "$bin_path" || "$rpath" == "$build_root/"* || "$rpath" == "$toolchain/"* || "$rpath" == /*/Metal.xctoolchain/* ]]; then
            install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/NoodleBrowser"
        fi
    done
identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"; fi
if [[ -z "$identity" ]]; then identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"; fi
[[ -n "$identity" && "$identity" != - ]] || { print -u2 'An Apple Development or Developer ID signing identity is required.'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && ( "$identity" != Developer\ ID\ Application:* || "$configuration" != release || "$data_container" != production ) ]]; then
    print -u2 'Releases require Developer ID and an optimized production build.'; exit 1
fi
timestamp_option="--timestamp=none"
if [[ "${NOODLE_CODESIGN_TIMESTAMP:-0}" == 1 ]]; then timestamp_option="--timestamp"; fi
codesign --force --options runtime "$timestamp_option" --sign "$identity" --identifier "$bundle_identifier" "$app/Contents/MacOS/NoodleBrowser"
team="$(codesign -dv --verbose=4 "$app/Contents/MacOS/NoodleBrowser" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Signing identity has no team identifier.'; exit 1; }
group="$team.$group_suffix"
/usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NoodleBrowserGroup string $group" "$app/Contents/Info.plist"
cp "$package/Support/Browser.entitlements" "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$staging/entitlements.plist"
# Same narrowly scoped Sparkle installer endpoints used by the suite.
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $bundle_identifier-spks" "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $bundle_identifier-spki" "$staging/entitlements.plist"
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "$timestamp_option" --sign "$identity" "$component"
done
codesign --force --options runtime "$timestamp_option" --sign "$identity" --entitlements "$staging/entitlements.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
zsh "$project_root/scripts/verify-browser.sh" "$app" >&2
destination="${NOODLE_BROWSER_APP_DESTINATION:-$project_root/.build/$app_name.app}"
[[ "$destination" == /* && "$destination" == *.app && "$destination" != /Applications/*.app ]] || { print -u2 'Use an absolute staging .app path outside /Applications.'; exit 1; }
mkdir -p "${destination:h}"
if pgrep -f "^$destination/Contents/MacOS/NoodleBrowser( |$)" >/dev/null; then
    print -u2 "Quit $app_name before replacing its build."; exit 1
fi
if [[ -d "$destination" ]]; then rm -rf "$destination"; fi
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
print "$destination"
