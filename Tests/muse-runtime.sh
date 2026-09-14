#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/MuseAgentProcess.swift" \
    "$project_root/Tests/muse-runtime.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/MuseRuntimeChecks"
"$project_root/.build/MuseRuntimeChecks"
