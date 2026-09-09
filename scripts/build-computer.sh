#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
configuration="${NOODLE_COMPUTER_CONFIGURATION:-release}"
package="$project_root/Computer"
build_root="$project_root/.build/computer"
destination_app="$project_root/.build/Noodle Computer.app"
bundle_identifier="com.pdparchitect.noodle.computer"
app_name="Noodle Computer"
menu_name="Computer"
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
cp "$package/Support/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app/Contents/Info.plist"
# Keep the menu's short name separate from the app's Finder/display name.
/usr/libexec/PlistBuddy -c "Set :CFBundleName $menu_name" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app/Contents/Info.plist"
cp "$kernel" "$app/Contents/Resources/Runtime/vmlinux-arm64"
cp "$package/Support/KERNEL-NOTICE.txt" "$app/Contents/Resources/KERNEL-NOTICE.txt"
cp "$package/Support/STUDIO-NOTICE.txt" "$app/Contents/Resources/STUDIO-NOTICE.txt"
swift "$package/Support/MakeIcon.swift" "$build_root/Computer.iconset"
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
signing_identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
codesign --force --options runtime --timestamp=none --entitlements "$package/Support/Computer.entitlements" --sign "${signing_identity:--}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
# Publish only a fully signed bundle. These are generated build artifacts, never
# the computer library or an installed application in /Applications.
if [[ -d "$destination_app" ]]; then rm -rf "$destination_app"; fi
mv "$app" "$destination_app"
print "$destination_app"
