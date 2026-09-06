#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${NOODLE_BUILD_CONFIGURATION:-release}"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
build_number="${NOODLE_BUILD_NUMBER:-$version}"
build_root="$project_root/.build"
app="$build_root/Noodle.app"
contents="$app/Contents"
module_cache="$build_root/module-cache"
entitlements="$project_root/Support/Noodle.entitlements"
asset_catalog="$project_root/Support/Assets.xcassets"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "VERSION must contain a semantic version such as 1.2.3."
    exit 1
fi

if [[ ! "$build_number" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
    print -u2 "NOODLE_BUILD_NUMBER must be a numeric bundle version such as 1.2.3."
    exit 1
fi

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

if ! xcodebuild -version >/dev/null 2>&1; then
    print -u2 "Full Xcode is required. Install Xcode, open it once, and accept its licence first."
    exit 1
fi

swift build --disable-sandbox --package-path "$project_root" --configuration "$configuration" >&2
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --configuration "$configuration" --show-bin-path)"
developer_dir="$(xcode-select -p)"
toolchain_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain"
sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
xcode_build_version="$(xcodebuild -version | awk '/Build version/ { print $3 }')"
target_arch="$(uname -m)"
intent_source_list="$build_root/Noodle.AppIntentSources"
intent_const_values_list="$build_root/Noodle.AppIntentConstValues"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Helpers"
sparkle_source="$build_root/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
sparkle="$contents/Frameworks/Sparkle.framework"
ditto "$sparkle_source" "$sparkle"
# The host already has network.client. Sparkle's separate downloader is unnecessary.
rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
share_extension="$contents/PlugIns/NoodleShare.appex"
mkdir -p "$share_extension/Contents/MacOS"
cp "$bin_path/NoodleShareExtension" "$share_extension/Contents/MacOS/NoodleShareExtension"
cp "$project_root/Support/ShareExtension-Info.plist" "$share_extension/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$share_extension/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$share_extension/Contents/Info.plist"
cp "$bin_path/Noodle" "$contents/MacOS/Noodle"
# SwiftPM adds development-only search paths. Keep system and bundle-relative paths.
otool -l "$contents/MacOS/Noodle" \
    | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }' \
    | while IFS= read -r rpath; do
        if [[ "$rpath" == "$bin_path" || "$rpath" == "$toolchain_dir/"* ]]; then
            install_name_tool -delete_rpath "$rpath" "$contents/MacOS/Noodle"
        fi
    done
cp "$bin_path/NoodleMessenger" "$contents/Helpers/messenger"
cp "$project_root/Support/Info.plist" "$contents/Info.plist"
agent_host="$contents/XPCServices/NoodleAgentHost.xpc"
mkdir -p "$agent_host/Contents/MacOS"
cp "$bin_path/NoodleAgentHost" "$agent_host/Contents/MacOS/NoodleAgentHost"
otool -l "$agent_host/Contents/MacOS/NoodleAgentHost" \
    | awk '/cmd LC_RPATH/ { found=1; next } found && /path / { print $2; found=0 }' \
    | while IFS= read -r rpath; do
        if [[ "$rpath" == "$bin_path" || "$rpath" == "$toolchain_dir/"* ]]; then
            install_name_tool -delete_rpath "$rpath" "$agent_host/Contents/MacOS/NoodleAgentHost"
        fi
    done
cp "$project_root/Support/AgentHost-Info.plist" "$agent_host/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$agent_host/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$agent_host/Contents/Info.plist"
cp "$project_root/.build/checkouts/Sparkle/LICENSE" "$contents/Resources/Sparkle-LICENSE.txt"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents/Info.plist"
xcrun actool "$asset_catalog" \
    --compile "$contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$build_root/asset-info.plist" >/dev/null

find "$project_root/Sources/Noodle" -type f -name '*.swift' -print | LC_ALL=C sort > "$intent_source_list"
find "$bin_path/Noodle.build" -type f -name '*.swiftconstvalues' -print | LC_ALL=C sort > "$intent_const_values_list"
xcrun appintentsmetadataprocessor \
    --toolchain-dir "$toolchain_dir" \
    --module-name Noodle \
    --sdk-root "$sdk_root" \
    --xcode-version "$xcode_build_version" \
    --platform-family macOS \
    --deployment-target 15.0 \
    --bundle-identifier com.pdparchitect.noodle \
    --output "$contents/Resources" \
    --target-triple "$target_arch-apple-macos15.0" \
    --binary-file "$bin_path/Noodle" \
    --source-file-list "$intent_source_list" \
    --swift-const-vals-list "$intent_const_values_list" \
    --force \
    --compile-time-extraction \
    --deployment-aware-processing \
    --validate-assistant-intents \
    --no-app-shortcuts-localization
test -f "$contents/Resources/Metadata.appintents/extract.actionsdata"

signing_identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | awk -F '"' '/Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
    print -u2 "No Apple Development identity found; using ad-hoc signing. App Intents may not be indexed until the app is signed with a development identity."
fi
if [[ "${NOODLE_REQUIRE_DEVELOPER_ID:-0}" == "1" && "$signing_identity" != Developer\ ID\ Application:* ]]; then
    print -u2 "A Developer ID Application signing identity is required for a public release."
    exit 1
fi

timestamp_option="--timestamp=none"
if [[ "${NOODLE_CODESIGN_TIMESTAMP:-0}" == "1" ]]; then
    timestamp_option="--timestamp"
fi

codesign --force --options runtime "$timestamp_option" \
    --sign "$signing_identity" "$contents/Helpers/messenger"
team_id="$(codesign -dv --verbose=4 "$contents/Helpers/messenger" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
if [[ ! "$team_id" =~ '^[A-Z0-9]{10}$' ]]; then
    print -u2 "Sharing requires an Apple Development or Developer ID identity with a team identifier."
    exit 1
fi
shared_group="$team_id.com.pdparchitect.noodle.sharing"
for file in "$contents/Info.plist" "$agent_host/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team_id" "$file"
done
# Explicitly approved opt-in boundary: authenticated, hardened, non-root XPC host.
# No sandbox inheritance, extra entitlements, or global Mach-service exception.
codesign --force --options runtime "$timestamp_option" --sign "$signing_identity" "$agent_host"
resolved_entitlements="$build_root/Noodle.resolved.entitlements"
share_entitlements="$build_root/ShareExtension.resolved.entitlements"
cp "$entitlements" "$resolved_entitlements"
cp "$project_root/Support/ShareExtension.entitlements" "$share_entitlements"
for file in "$resolved_entitlements" "$share_entitlements"; do
    /usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $shared_group" "$file"
done
for file in "$contents/Info.plist" "$share_extension/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Add :NoodleSharedGroup string $shared_group" "$file"
done
codesign --force --options runtime "$timestamp_option" \
    --entitlements "$share_entitlements" --sign "$signing_identity" "$share_extension"
# Sign Sparkle inside-out. These installer components are deliberately outside the
# host's sandbox so they can replace the signed app; no other app permissions change.
for component in \
    "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app" \
    "$sparkle"; do
    codesign --force --options runtime "$timestamp_option" --sign "$signing_identity" "$component"
done
codesign --force --options runtime "$timestamp_option" \
    --entitlements "$resolved_entitlements" \
    --sign "$signing_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
zsh "$project_root/scripts/verify-updater.sh" "$app" >&2
zsh "$project_root/scripts/verify-agent-host.sh" "$app" >&2

print "$app"
