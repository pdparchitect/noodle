#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/VoiceRecorder.swift" \
    "$project_root/Sources/Noodle/VoiceInputDevice.swift" \
    "$project_root/Tests/voice-recording.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    -o "$project_root/.build/voice-recording-tests"
"$project_root/.build/voice-recording-tests" "$@"
