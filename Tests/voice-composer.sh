#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/VoiceRecorder.swift" \
    "$project_root/Sources/Noodle/VoiceInputDevice.swift" \
    "$project_root/Sources/Noodle/VoiceMessagePlayer.swift" \
    "$project_root/Sources/Noodle/VoiceMessageComposer.swift" \
    "$project_root/Sources/Noodle/VoiceRecordingCommand.swift" \
    "$project_root/Tests/NativeFixtureChecks.swift" \
    "$project_root/Tests/voice-composer.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o \
    -o "$project_root/.build/voice-composer-tests"
"$project_root/.build/voice-composer-tests"
