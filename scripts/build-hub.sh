#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
package="$project_root/Hub"
build_root="$project_root/.build/hub"
configuration="${NOODLE_HUB_CONFIGURATION:-release}"
data_container="${NOODLE_HUB_DATA_CONTAINER:-${NOODLE_DATA_CONTAINER:-development}}"
case "$data_container" in
    development) bundle_identifier="com.pdparchitect.noodle.hub.local"; app_name="Noodle Hub Dev" ;;
    production) bundle_identifier="com.pdparchitect.noodle.hub"; app_name="Noodle Hub" ;;
    *) print -u2 'NOODLE_HUB_DATA_CONTAINER must be development or production.'; exit 1 ;;
esac
version="$(tr -d '[:space:]' < "$package/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Hub/VERSION'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && ( "$configuration" != release || "$data_container" != production ) ]]; then
    print -u2 'Public releases require the optimized production Hub identity.'; exit 1
fi
# Package.swift reads this. A development bundle keeps its development hooks;
# a production bundle never has them, whatever the calling shell exports.
if [[ "$data_container" == development ]]; then export NOODLE_DEV_HOOKS=1; else unset NOODLE_DEV_HOOKS; fi
# Build the app like Noodle, with the selected Xcode's SDK, so it links against it.
xcode_swift() {
    NOODLE_SWIFT="$(xcrun --find swift)" NOODLE_MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)" \
        zsh "$project_root/scripts/swift-apple.sh" "$@"
}
xcode_swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" >&2
bin_path="$(xcode_swift build --disable-sandbox --package-path "$package" --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
python3 "$project_root/scripts/verify-build-sdk.py" "$bin_path/NoodleHub" "$(xcrun --sdk macosx --show-sdk-version)" >&2

# The Hub runs bots with Noodle's runtime, so it carries Noodle's helpers: the Agent Host
# and messenger built like Noodle's, and the Apple harness built with the newest SDK.
for product in NoodleAgentHost NoodleMessenger; do
    xcode_swift build --disable-sandbox --package-path "$project_root" -c "$configuration" --product "$product" >&2
done
helper_bin="$(xcode_swift build --disable-sandbox --package-path "$project_root" -c "$configuration" --show-bin-path)"
zsh "$project_root/scripts/swift-apple.sh" build --disable-sandbox --package-path "$project_root" -c "$configuration" --product NoodleAppleAgent >&2
apple_bin="$(zsh "$project_root/scripts/swift-apple.sh" build --disable-sandbox --package-path "$project_root" -c "$configuration" --show-bin-path)"
apple27="$("$apple_bin/NoodleAppleAgent" --build-capabilities | plutil -extract apple27 raw -o - -)"
if [[ "${NOODLE_REQUIRE_APPLE27:-0}" == 1 && "$apple27" != true ]]; then
    print -u2 "This release requires an Apple helper compiled with the macOS 27 SDK."
    exit 1
fi
if [[ "$apple27" == true ]]; then
    zsh "$project_root/scripts/build-mlx-metal.sh" "$apple_bin" >&2
fi

staging="$(mktemp -d "$build_root/App.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/$app_name.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Helpers" "$contents/Resources"
cp "$bin_path/NoodleHub" "$contents/MacOS/"
cp "$helper_bin/NoodleMessenger" "$contents/Helpers/messenger"
cp "$apple_bin/NoodleAppleAgent" "$contents/Helpers/NoodleAppleAgent"
for resource in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
    if [[ -d "$apple_bin/$resource.bundle" || "$resource" == mlx-swift_Cmlx && -f "$apple_bin/mlx.metallib" ]]; then
        destination="$contents/Helpers/$resource.bundle"
        if [[ -d "$apple_bin/$resource.bundle/Contents" ]]; then
            ditto "$apple_bin/$resource.bundle" "$destination"
        else
            # Native SwiftPM emits flat resource folders without metadata.
            # Give them a macOS bundle layout so nested signing can seal them.
            mkdir -p "$destination/Contents/Resources"
            if [[ -d "$apple_bin/$resource.bundle" ]]; then
                ditto "$apple_bin/$resource.bundle" "$destination/Contents/Resources"
            fi
            cat > "$destination/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pdparchitect.noodle.resources.${resource//_/-}</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
EOF
        fi
    fi
done
# MLX also resolves default.metallib in its SwiftPM resource bundle. Store it
# there so signing treats it as a sealed resource, not an unsigned helper.
packaged_metal="$contents/Helpers/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [[ -f "$apple_bin/mlx.metallib" ]]; then
    cp "$apple_bin/mlx.metallib" "$packaged_metal"
fi
if [[ ! -f "$packaged_metal" && "$apple27" == true ]]; then
    print -u2 "Local model support requires compiled MLX Metal shaders. Install Xcode's Metal Toolchain and rebuild with scripts/swift-apple.sh."
    exit 1
fi
agent_host="$contents/XPCServices/NoodleAgentHost.xpc"
mkdir -p "$agent_host/Contents/MacOS"
cp "$helper_bin/NoodleAgentHost" "$agent_host/Contents/MacOS/NoodleAgentHost"
cp "$project_root/Support/AgentHost-Info.plist" "$agent_host/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier.agent-host" "$agent_host/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$agent_host/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$agent_host/Contents/Info.plist"
# SwiftPM adds development-only search paths. Keep system and bundle-relative paths.
toolchain="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
for executable in "$contents/MacOS/NoodleHub" "$contents/Helpers/NoodleAppleAgent" "$agent_host/Contents/MacOS/NoodleAgentHost"; do
    otool -l "$executable" | awk '/cmd LC_RPATH/ {found=1;next} found && /path / {print $2;found=0}' |
        while IFS= read -r rpath; do
            if [[ "$rpath" == "$bin_path" || "$rpath" == "$helper_bin" || "$rpath" == "$apple_bin" || "$rpath" == "$toolchain/"* ||
                  "$rpath" == /Library/Developer/CommandLineTools/* || "$rpath" == /*/Metal.xctoolchain/* ]]; then
                install_name_tool -delete_rpath "$rpath" "$executable"
            fi
        done
done
checkouts="$project_root/.build/checkouts"
for dependency in mlx-swift mlx-swift-lm swift-transformers swift-jinja swift-huggingface swift-crypto swift-numerics swift-collections swift-argument-parser swift-asn1 yyjson; do
    if [[ -f "$checkouts/$dependency/LICENSE" ]]; then
        cp "$checkouts/$dependency/LICENSE" "$contents/Resources/$dependency-LICENSE.txt"
    elif [[ -f "$checkouts/$dependency/LICENSE.txt" ]]; then
        cp "$checkouts/$dependency/LICENSE.txt" "$contents/Resources/$dependency-LICENSE.txt"
    fi
done
cp "$checkouts/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/LICENSE" "$contents/Resources/xgrammar-LICENSE.txt"
sparkle="$contents/Frameworks/Sparkle.framework"
mkdir -p "$contents/Frameworks"
ditto "$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$sparkle"
# The app already has outbound network access, matching the other apps' Sparkle setup.
rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
cp "$build_root/checkouts/Sparkle/LICENSE" "$contents/Resources/Sparkle-LICENSE.txt"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$contents/MacOS/NoodleHub"
cp "$package/Support/Info.plist" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$contents/Info.plist"
updates_enabled=false
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 ]]; then updates_enabled=true; fi
/usr/libexec/PlistBuddy -c "Add :NoodleUpdatesEnabled bool $updates_enabled" "$contents/Info.plist"
zsh "$project_root/scripts/generate-icon.sh" "$package/Support/AppSymbol.svg" "$staging/Hub.iconset" >&2
iconutil -c icns "$staging/Hub.iconset" -o "$contents/Resources/Hub.icns"
cp "$package/Support/AppSymbol.svg" "$contents/Resources/AppSymbol.svg"
# The settings shared with Noodle draw harness marks and tool icons from the app's resources.
xcrun actool "$project_root/Support/Assets.xcassets" --compile "$contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --output-partial-info-plist "$staging/asset-info.plist" >/dev/null
ditto "$project_root/Support/ToolIcons" "$contents/Resources/ToolIcons"

identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"; fi
if [[ -z "$identity" ]]; then identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)"; fi
[[ -n "$identity" && "$identity" != - ]] || { print -u2 'An Apple Development or Developer ID signing identity is required.'; exit 1; }
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$identity" != Developer\ ID\ Application:* ]]; then
    print -u2 'Public releases require a Developer ID Application identity.'; exit 1
fi
timestamp_option="--timestamp=none"
if [[ "${NOODLE_CODESIGN_TIMESTAMP:-0}" == 1 ]]; then timestamp_option="--timestamp"; fi
codesign --force --options runtime "$timestamp_option" --sign "$identity" "$contents/Helpers/messenger"
team="$(codesign -dv --verbose=4 "$contents/Helpers/messenger" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'Signing identity has no team identifier.'; exit 1; }
# Agent Host applies this helper's own Seatbelt policy before exec, as in Noodle.
codesign --force --options runtime "$timestamp_option" --identifier "$bundle_identifier.apple-agent" \
    --sign "$identity" "$contents/Helpers/NoodleAppleAgent"
for resource in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
    if [[ -d "$contents/Helpers/$resource.bundle" ]]; then
        codesign --force "$timestamp_option" --sign "$identity" "$contents/Helpers/$resource.bundle"
    fi
done
# The Hub and its Agent Host accept only each other, as Noodle and its own do.
for file in "$contents/Info.plist" "$agent_host/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team" "$file"
    /usr/libexec/PlistBuddy -c "Add :NoodleApplicationIdentifier string $bundle_identifier" "$file"
    /usr/libexec/PlistBuddy -c "Add :NoodleAgentHostService string $bundle_identifier.agent-host" "$file"
done
codesign --force --options runtime "$timestamp_option" --sign "$identity" "$agent_host"
cp "$package/Support/Hub.entitlements" "$staging/entitlements.plist"
# Same two narrowly scoped Sparkle installer endpoints as the other apps.
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.temporary-exception.mach-lookup.global-name array' "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:0 string $bundle_identifier-spks" "$staging/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.temporary-exception.mach-lookup.global-name:1 string $bundle_identifier-spki" "$staging/entitlements.plist"
# Sign Sparkle inside-out. Its installer stays outside the app's sandbox so it can replace the app.
for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle"; do
    codesign --force --options runtime "$timestamp_option" --sign "$identity" "$component"
done
codesign --force --options runtime "$timestamp_option" --sign "$identity" \
    --entitlements "$staging/entitlements.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
zsh "$project_root/scripts/verify-hub-release.sh" "$app" >&2
destination="$project_root/.build/$app_name.app"
if [[ -d "$destination" ]]; then rm -rf "$destination"; fi
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
print "$destination"
