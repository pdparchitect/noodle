#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
package="$project_root/Applet"
build_root="$project_root/.build/applet"
configuration="${NOODLE_APPLET_CONFIGURATION:-release}"
data_container="${NOODLE_APPLET_DATA_CONTAINER:-${NOODLE_DATA_CONTAINER:-development}}"
case "$data_container" in
    development) bundle_identifier="com.pdparchitect.noodle.applet.local"; app_name="Noodle Applet Dev"; group_suffix="com.pdparchitect.noodle.applets.local"; document_extension="noodlet-dev"; help_option="--write-applet-dev-help" ;;
    production) bundle_identifier="com.pdparchitect.noodle.applet"; app_name="Noodle Applet"; group_suffix="com.pdparchitect.noodle.applets"; document_extension="noodlet"; help_option="--write-applet-help" ;;
    *) print -u2 'NOODLE_APPLET_DATA_CONTAINER must be development or production.'; exit 1 ;;
esac
content_type="com.pdparchitect.noodle.$document_extension"
version="$(tr -d '[:space:]' < "$package/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Applet/VERSION'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && ( "$configuration" != release || "$data_container" != production ) ]]; then
    print -u2 'Public releases require the optimized production Applet identity.'; exit 1
fi
swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" >&2
bin_path="$(swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
swiftc -typecheck -parse-as-library -swift-version 5 -module-cache-path "$build_root/RuntimeCheckCache" \
    "$package/Sources/NoodleApplet/Resources/NoodletRuntime.swift" \
    "$package/Sources/NoodleApplet/Resources/Examples/Orbit.noodlet/Orbit.swift"
staging="$(mktemp -d "$build_root/App.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/$app_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin_path/NoodleApplet" "$app/Contents/MacOS/"
cp "$bin_path/noodlet" "$app/Contents/Helpers/"
preview="$app/Contents/PlugIns/NoodletPreview.appex"
mkdir -p "$preview/Contents/MacOS"
cp "$bin_path/NoodletPreview" "$preview/Contents/MacOS/"
cp "$package/Support/Preview-Info.plist" "$preview/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier.preview" "$preview/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :NSExtension:NSExtensionAttributes:QLSupportedContentTypes:0 $content_type" "$preview/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$preview/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$preview/Contents/Info.plist"
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
for executable in "$app/Contents/MacOS/NoodleApplet" "$app/Contents/Helpers/noodlet" "$preview/Contents/MacOS/NoodletPreview"; do
    otool -l "$executable" | awk '/cmd LC_RPATH/ {found=1;next} found && /path / {print $2;found=0}' |
        while IFS= read -r rpath; do
            if [[ "$rpath" == "$bin_path" || "$rpath" == "$toolchain/"* || "$rpath" == /*/Metal.xctoolchain/* ]]; then install_name_tool -delete_rpath "$rpath" "$executable"; fi
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
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $bundle_identifier.link" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $document_extension" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDocumentTypes:0:LSItemContentTypes:0 $content_type" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :UTExportedTypeDeclarations:0:UTTypeIdentifier $content_type" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0 $document_extension" "$app/Contents/Info.plist"
# Only bundled examples are renamed. Never migrate or open a user's production documents.
if [[ "$data_container" == development ]]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDocumentTypes:0:CFBundleTypeName Noodlet Dev' "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :UTExportedTypeDeclarations:0:UTTypeDescription Noodlet Dev' "$app/Contents/Info.plist"
    for example in "$app/Contents/Resources/NoodleApplet_NoodleApplet.bundle"/**/Examples/*.noodlet(N); do
        mv "$example" "${example%.noodlet}.noodlet-dev"
    done
fi
swift run --disable-sandbox --package-path "$project_root" NoodleDocumentation "$help_option" "$app/Contents/Resources/NoodletCLIHelp.txt" >&2
updates_enabled=false
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then updates_enabled=true; fi
/usr/libexec/PlistBuddy -c "Add :NoodleUpdatesEnabled bool $updates_enabled" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
zsh "$project_root/scripts/generate-icon.sh" "$package/Support/AppSymbol.svg" "$staging/Applet.iconset" >&2
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
codesign --force --options runtime "$timestamp_option" --sign "$identity" --identifier "$bundle_identifier.cli" "$app/Contents/Helpers/noodlet"
team="$(codesign -dv --verbose=4 "$app/Contents/Helpers/noodlet" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Signing identity has no team identifier.'; exit 1; }
group="$team.$group_suffix"
/usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NoodleAppletGroup string $group" "$app/Contents/Info.plist"
cp "$package/Support/Applet.entitlements" "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$staging/entitlements.plist"
# Same two narrowly scoped Sparkle installer endpoints as Noodle and Computer.
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $bundle_identifier-spks" "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $bundle_identifier-spki" "$staging/entitlements.plist"
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
destination="$project_root/.build/$app_name.app"
if [[ -d "$destination" ]]; then rm -rf "$destination"; fi
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
print "$destination"
