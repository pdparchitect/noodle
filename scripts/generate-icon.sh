#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_png="$project_root/Support/AppIcon.png"
iconset="$project_root/Support/Assets.xcassets/AppIcon.appiconset"

# The approved artwork is the source of truth. Only derive catalog sizes here;
# never redraw or overwrite the master when regenerating the icon.
if [[ ! -f "$source_png" ]]; then
    print -u2 "Missing approved icon artwork: $source_png"
    exit 1
fi

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

print "Generated the Noodle AppIcon asset catalog"
