#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root/Shared/Wallpaper" --scratch-path "$project_root/.build/wallpaper"
bin_path="$(swift build --disable-sandbox --package-path "$project_root/Shared/Wallpaper" --scratch-path "$project_root/.build/wallpaper" --show-bin-path)"
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Tests/animated-backgrounds.swift" \
    "$bin_path"/NoodleWallpaperCore.build/*.swift.o "$bin_path"/NoodleWallpaper.build/*.swift.o \
    -o "$project_root/.build/AnimatedBackgroundChecks"
"$project_root/.build/AnimatedBackgroundChecks" "$@"
