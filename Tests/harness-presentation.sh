#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/HarnessSetupController.swift" \
    "$project_root/Tests/harness-presentation.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    -o "$project_root/.build/HarnessPresentationChecks"
"$project_root/.build/HarnessPresentationChecks"
