#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --product NoodleMessenger
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/MuseAgentProcess.swift" \
    "$project_root/Tests/muse-live.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/MuseLiveChecks"
"$project_root/.build/MuseLiveChecks" "$bin_path/NoodleMessenger"
