#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bash "$here/build-arena.sh" "$DERIVED_FILE_DIR/neptune"
build="$(cat "$DERIVED_FILE_DIR/neptune/current")"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/neptune"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
rm -rf "$frameworks"
mkdir -p "$frameworks"
ditto "$build/dependencies/frameworks" "$frameworks"
cp "$build/out/lib/libvirglrenderer.1.dylib" "$frameworks/libvirglrenderer-neptune.dylib"
cp "$build/out/lib/libepoxy.0.dylib" "$frameworks/libepoxy-angle.0.dylib"
old_epoxy="$(otool -L "$frameworks/libvirglrenderer-neptune.dylib" | awk '/libepoxy/ {print $1}')"
install_name_tool -id @rpath/libvirglrenderer-neptune.dylib -change "$old_epoxy" @loader_path/libepoxy-angle.0.dylib "$frameworks/libvirglrenderer-neptune.dylib"
install_name_tool -id @rpath/libepoxy-angle.0.dylib "$frameworks/libepoxy-angle.0.dylib"
for item in "$frameworks"/*.dylib "$frameworks"/*.framework; do
    codesign --force --options runtime "$COMPUTER_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$item"
done
rm -rf "$resources/neptune-guest" "$resources/NeptuneLicenses"
ditto "$build/dependencies/neptune-guest" "$resources/neptune-guest"
ditto "$build/dependencies/licenses" "$resources/NeptuneLicenses"
cp "$build/renderer/COPYING" "$resources/NeptuneLicenses/virglrenderer.txt"
cp "$build/libepoxy/COPYING" "$resources/NeptuneLicenses/libepoxy.txt"
cp "$SRCROOT/Vendor/dxmt-70aa109c50aa-sources.tar.gz" "$resources/NeptuneLicenses/"
helper="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/noodle-windows-renderer"
ditto "$BUILT_PRODUCTS_DIR/noodle-windows-renderer" "$helper"
codesign --force --options runtime "$COMPUTER_CODESIGN_TIMESTAMP" --identifier "$PRODUCT_BUNDLE_IDENTIFIER.renderer" \
    --entitlements "$SRCROOT/Support/Neptune/Renderer.entitlements" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helper"

if [ "$CONFIGURATION" != Release ]; then
    mkdir -p "$resources/neptune-probe"
    cp "$SRCROOT/Tests/NeptuneArenaTests/Direct3DProbe.cs" "$resources/neptune-probe/"
fi
