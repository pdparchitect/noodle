#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
swift build --disable-sandbox --package-path "$project_root" --target NoodleAudioCapture
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    -I "$project_root/Sources/NoodleAudioCapture/include" \
    -Xcc -fmodule-map-file="$bin_path/NoodleAudioCapture.build/module.modulemap" \
    "$project_root/Sources/Noodle/VoiceRecorder.swift" \
    "$project_root/Sources/Noodle/VoiceCaptureRecovery.swift" \
    "$project_root/Sources/Noodle/VoiceInputDevice.swift" \
    "$project_root/Tests/voice-recording.swift" \
    "${core_objects[@]}" \
    "$bin_path"/NoodleAudioCapture.build/*.o \
    -o "$project_root/.build/voice-recording-tests"
"$project_root/.build/voice-recording-tests" "$@"
