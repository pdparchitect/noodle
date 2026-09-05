#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${SUPERBOT_BUILD_CONFIGURATION:-release}"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
build_number="${SUPERBOT_BUILD_NUMBER:-$(git -C "$project_root" rev-list --count HEAD 2>/dev/null || print 1)}"
build_root="$project_root/.build"
app="$build_root/SuperBot.app"
contents="$app/Contents"
module_cache="$build_root/module-cache"
entitlements="$project_root/Support/SuperBot.entitlements"
asset_catalog="$project_root/Support/Assets.xcassets"

if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
    print -u2 "VERSION must contain a semantic version such as 1.2.3."
    exit 1
fi

if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "SUPERBOT_BUILD_NUMBER must be a positive integer."
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
intent_source_list="$build_root/SuperBot.AppIntentSources"
intent_const_values_list="$build_root/SuperBot.AppIntentConstValues"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources" "$contents/Helpers"
cp "$bin_path/SuperBot" "$contents/MacOS/SuperBot"
cp "$bin_path/SuperBotMessenger" "$contents/Helpers/messenger"
cp "$project_root/Support/Info.plist" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents/Info.plist"
xcrun actool "$asset_catalog" \
    --compile "$contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$build_root/asset-info.plist" >/dev/null

find "$project_root/Sources/SuperBot" -type f -name '*.swift' -print | LC_ALL=C sort > "$intent_source_list"
find "$bin_path/SuperBot.build" -type f -name '*.swiftconstvalues' -print | LC_ALL=C sort > "$intent_const_values_list"
xcrun appintentsmetadataprocessor \
    --toolchain-dir "$toolchain_dir" \
    --module-name SuperBot \
    --sdk-root "$sdk_root" \
    --xcode-version "$xcode_build_version" \
    --platform-family macOS \
    --deployment-target 15.0 \
    --bundle-identifier com.pdparchitect.superbot \
    --output "$contents/Resources" \
    --target-triple "$target_arch-apple-macos15.0" \
    --binary-file "$bin_path/SuperBot" \
    --source-file-list "$intent_source_list" \
    --swift-const-vals-list "$intent_const_values_list" \
    --force \
    --compile-time-extraction \
    --deployment-aware-processing \
    --validate-assistant-intents \
    --no-app-shortcuts-localization
test -f "$contents/Resources/Metadata.appintents/extract.actionsdata"

signing_identity="${SUPERBOT_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | awk -F '"' '/Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
    print -u2 "No Apple Development identity found; using ad-hoc signing. App Intents may not be indexed until the app is signed with a development identity."
fi
if [[ "${SUPERBOT_REQUIRE_DEVELOPER_ID:-0}" == "1" && "$signing_identity" != Developer\ ID\ Application:* ]]; then
    print -u2 "A Developer ID Application signing identity is required for a public release."
    exit 1
fi

timestamp_option="--timestamp=none"
if [[ "${SUPERBOT_CODESIGN_TIMESTAMP:-0}" == "1" ]]; then
    timestamp_option="--timestamp"
fi

codesign --force --options runtime "$timestamp_option" \
    --sign "$signing_identity" "$contents/Helpers/messenger"
codesign --force --options runtime "$timestamp_option" \
    --entitlements "$entitlements" \
    --sign "$signing_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

print "$app"
