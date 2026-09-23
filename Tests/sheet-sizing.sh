#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleRuntimeSettings
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path" NoodleRuntimeSettings NoodleRuntime NoodleAgentBridge NoodleSettingsUI NoodleWallpaper)}")
swiftc -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/GroupMemberPicker.swift" \
    "$project_root/Tests/sheet-sizing.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/sheet-sizing-tests"
"$project_root/.build/sheet-sizing-tests"
"$project_root/.build/sheet-sizing-tests" --animated
