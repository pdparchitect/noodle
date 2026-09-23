#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --build-system native --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --build-system native --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
swiftc -parse-as-library -package-name noodle -I "$bin_path/Modules" \
    "$project_root/Sources/NoodleRuntime/RuntimeShutdown.swift" \
    "$project_root/Sources/NoodleRuntime/HarnessRuntimeConnection.swift" \
    "$project_root/Sources/NoodleRuntime/MuseAgentProcess.swift" \
    "$project_root/Sources/NoodleRuntime/AntigravityAgentProcess.swift" \
    "$project_root/Tests/muse-runtime.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/MuseRuntimeChecks"
"$project_root/.build/MuseRuntimeChecks"
