#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/AnimatedWallpaper.swift" \
    "$project_root/Tests/animated-backgrounds.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o \
    -o "$project_root/.build/AnimatedBackgroundChecks"
"$project_root/.build/AnimatedBackgroundChecks" "$@"
