#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swiftc -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/SheetSizing.swift" \
    "$project_root/Sources/Noodle/GroupMemberPicker.swift" \
    "$project_root/Tests/sheet-sizing.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    -o "$project_root/.build/sheet-sizing-tests"
"$project_root/.build/sheet-sizing-tests"
"$project_root/.build/sheet-sizing-tests" --animated
