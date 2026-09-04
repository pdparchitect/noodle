#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${SUPERBOT_BUILD_CONFIGURATION:-release}"
build_root="$project_root/.build"
app="$build_root/SuperBot.app"
contents="$app/Contents"
module_cache="$build_root/module-cache"
entitlements="$project_root/Support/SuperBot.entitlements"
asset_catalog="$project_root/Support/Assets.xcassets"

mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

if ! xcodebuild -version >/dev/null 2>&1; then
    print -u2 "Full Xcode is required. Install Xcode, open it once, and accept its licence first."
    exit 1
fi

swift build --disable-sandbox --package-path "$project_root" --configuration "$configuration" >&2
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --configuration "$configuration" --show-bin-path)"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_path/SuperBot" "$contents/MacOS/SuperBot"
cp "$project_root/Support/Info.plist" "$contents/Info.plist"
xcrun actool "$asset_catalog" \
    --compile "$contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$build_root/asset-info.plist" >/dev/null

signing_identity="${SUPERBOT_SIGNING_IDENTITY:--}"
codesign --force --deep --options runtime --timestamp=none \
    --entitlements "$entitlements" \
    --sign "$signing_identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

print "$app"
