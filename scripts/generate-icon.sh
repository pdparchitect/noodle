#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="$project_root/.build/icon-generation"
source_png="$project_root/Support/AppIcon.png"
iconset="$project_root/Support/Assets.xcassets/AppIcon.appiconset"

mkdir -p "$build_root/module-cache"
swiftc \
    -module-cache-path "$build_root/module-cache" \
    "$project_root/scripts/generate-icon.swift" \
    -o "$build_root/generate-icon"
"$build_root/generate-icon" "$source_png"

mkdir -p "$iconset"

for entry in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' \
    '1024 icon_512x512@2x.png'
do
    size="${entry%% *}"
    filename="${entry#* }"
    sips -z "$size" "$size" "$source_png" --out "$iconset/$filename" >/dev/null
done

print "Generated the SuperBot AppIcon asset catalog"
