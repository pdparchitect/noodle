#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/ConversationTransition.swift" \
    "$project_root/Sources/Noodle/TranscriptScrollView.swift" \
    "$project_root/Tests/transcript-startup.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/TranscriptStartupChecks"
"$project_root/.build/TranscriptStartupChecks"
