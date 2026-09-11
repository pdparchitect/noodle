#!/bin/zsh
set -euo pipefail
command -v go >/dev/null || { print -u2 'Building Computer requires Go for its Linux guest file helper.'; exit 1; }
project_root="${0:A:h:h}"
configuration="${NOODLE_COMPUTER_CONFIGURATION:-release}"
package="$project_root/Computer"
build_root="$project_root/.build/computer"
destination_app="$project_root/.build/Noodle Computer.app"
bundle_identifier="com.pdparchitect.noodle.computer"
app_name="Noodle Computer"
menu_name="Computer"
version="$(tr -d '[:space:]' < "$package/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Computer/VERSION'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && ( "${NOODLE_COMPUTER_TEST_BUILD:-0}" == 1 || "$configuration" != release ) ]]; then
    print -u2 'Public releases require the optimized production Computer identity.'; exit 1
fi
if [[ "${NOODLE_COMPUTER_TEST_BUILD:-0}" == 1 ]]; then
    app_name="Noodle Computer Tests"
    menu_name="Computer Tests"
    destination_app="$project_root/.build/$app_name.app"
    bundle_identifier="com.pdparchitect.noodle.computer.tests"
fi
kernel="$package/Resources/Runtime/vmlinux-arm64"
if [[ "$(uname -m)" != arm64 ]]; then
    print -u2 "Noodle Computer currently requires Apple silicon."
    exit 1
fi
if [[ ! -f "$kernel" ]] || [[ "$(stat -f %z "$kernel")" -lt 1000000 ]]; then
    print -u2 "Missing runtime kernel. See Computer/README.md (git lfs pull)."
    exit 1
fi
expected_kernel="fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d"
actual_kernel="$(shasum -a 256 "$kernel" | awk '{print $1}')"
if [[ "$actual_kernel" != "$expected_kernel" ]]; then
    print -u2 "The runtime kernel does not match its pinned checksum."
    exit 1
fi
swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" --product NoodleComputer >&2
bin_path="$(swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
staging_root="$(mktemp -d "$build_root/App.XXXXXX")"
trap 'rm -rf "$staging_root"' EXIT
app="$staging_root/$app_name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Runtime"
cp "$bin_path/NoodleComputer" "$app/Contents/MacOS/NoodleComputer"
cp -R "$bin_path/SwiftTerm_SwiftTerm.bundle" "$app/Contents/Resources/"
cp -R "$bin_path/NoodleComputer_ComputerCore.bundle" "$app/Contents/Resources/"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app/Contents/Frameworks"
ditto "$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$sparkle"
# Outbound networking is already granted; omit Sparkle's downloader service.
rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
# The dependency-licence loop below also copies Sparkle-LICENSE.txt.
cp "$package/Support/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
# Keep the menu's short name separate from the app's Finder/display name.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $menu_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$app/Contents/Info.plist"
updates_enabled=false
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then updates_enabled=true; fi
if [[ "${NOODLE_COMPUTER_TEST_UPDATES:-0}" == 1 ]]; then
    [[ "${NOODLE_COMPUTER_TEST_BUILD:-0}" == 1 ]] || { print -u2 'Updater UI testing requires the isolated test bundle.'; exit 1; }
    updates_enabled=true
fi
/usr/libexec/PlistBuddy -c "Add :NoodleUpdatesEnabled bool $updates_enabled" "$app/Contents/Info.plist"
cp "$kernel" "$app/Contents/Resources/Runtime/vmlinux-arm64"
# A static Linux/ARM64 helper runs inside the guest, never as a host executable.
mkdir -p "$build_root/guest-tools"
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' -o "$build_root/guest-tools/noodle-files" "$package/GuestFiles/main.go"
cp "$build_root/guest-tools/noodle-files" "$app/Contents/Resources/Runtime/noodle-files"
cp "$package/Support/KERNEL-NOTICE.txt" "$app/Contents/Resources/KERNEL-NOTICE.txt"
cp "$package/Support/STUDIO-NOTICE.txt" "$app/Contents/Resources/STUDIO-NOTICE.txt"
swift "$package/Support/MakeIcon.swift" "$build_root/Computer.iconset" "$package/Support/AppIcon.png"
iconutil -c icns "$build_root/Computer.iconset" -o "$app/Contents/Resources/Computer.icns"
for dependency in "$build_root"/checkouts/*; do
    for license in "$dependency"/LICENSE(N) "$dependency"/LICENSE.txt(N) "$dependency"/COPYING(N); do
        cp "$license" "$app/Contents/Resources/${dependency:t}-${license:t}.txt"
    done
done
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
otool -l "$app/Contents/MacOS/NoodleComputer" | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }' |
    while IFS= read -r rpath; do
        if [[ "$rpath" == "$bin_path" || "$rpath" == "$toolchain/"* ]]; then
            install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/NoodleComputer"
        fi
    done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/NoodleComputer"
signing_identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"
fi
if [[ -z "$signing_identity" || "$signing_identity" == - ]]; then
    print -u2 "Computer integration requires an Apple Development or Developer ID signing identity."
    exit 1
fi
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$signing_identity" != Developer\ ID\ Application:* ]]; then
    print -u2 'Public releases require a Developer ID Application identity.'; exit 1
fi
timestamp_option="--timestamp=none"
if [[ "${NOODLE_CODESIGN_TIMESTAMP:-0}" == 1 ]]; then timestamp_option="--timestamp"; fi
codesign --force --options runtime "$timestamp_option" --sign "$signing_identity" "$app/Contents/MacOS/NoodleComputer"
team_id="$(codesign -dv --verbose=4 "$app/Contents/MacOS/NoodleComputer" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
if [[ ! "$team_id" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "The Computer signing identity has no valid team identifier."
    exit 1
fi
computer_group="$team_id.com.pdparchitect.noodle.computers"
/usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team_id" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :NoodleComputerGroup string $computer_group" "$app/Contents/Info.plist"
resolved_entitlements="$staging_root/Computer.entitlements"
cp "$package/Support/Computer.entitlements" "$resolved_entitlements"
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$resolved_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $computer_group" "$resolved_entitlements"
# Approved Sparkle boundary, matching Noodle: only its own two installer services.
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$resolved_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $bundle_identifier-spks" "$resolved_entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $bundle_identifier-spki" "$resolved_entitlements"
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "$timestamp_option" --sign "$signing_identity" "$component"
done
codesign --force --options runtime "$timestamp_option" --entitlements "$resolved_entitlements" --sign "$signing_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
zsh "$project_root/scripts/verify-computer-release.sh" "$app" >&2
# Publish only a fully signed bundle. These are generated build artifacts, never
# the computer library or an installed application in /Applications.
if [[ -d "$destination_app" ]]; then rm -rf "$destination_app"; fi
mv "$app" "$destination_app"
print "$destination_app"
