#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
swift build --disable-sandbox --package-path "$project_root" --target NoodleAudioCapture
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
fixture_app="$project_root/.build/Noodle Voice Startup Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
swiftc -O -parse-as-library -I "$bin_path/Modules" \
    -I "$project_root/Sources/NoodleAudioCapture/include" \
    -Xcc -fmodule-map-file="$bin_path/NoodleAudioCapture.build/module.modulemap" \
    "$project_root/Sources/Noodle/VoiceRecorder.swift" \
    "$project_root/Sources/Noodle/VoiceInputDevice.swift" \
    "$project_root/Sources/Noodle/VoiceCaptureRecovery.swift" \
    "$project_root/Tests/voice-startup.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o "$bin_path"/NoodleAudioCapture.build/*.o \
    -o "$fixture_app/Contents/MacOS/VoiceStartupTests"
cp "$project_root/Tests/voice-startup-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$project_root/Tests/voice-startup.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
codesign -d --entitlements :- "$fixture_app"
if otool -L "$fixture_app/Contents/MacOS/VoiceStartupTests" | rg -q '/opt/homebrew|/usr/local'; then
    print -u2 "The fixture must not link against mutable external libraries."
    exit 1
fi
if [[ "${1:-}" != "--live" ]]; then
    print "Built. Pass --live to activate the microphone for ten startup checks."
    exit 0
fi
test_log="$project_root/.build/voice-startup-live.log"
open -W --stdout "$test_log" --stderr "$test_log" "$fixture_app" --args "$@"
cat "$test_log"
rg -q '^PASS: 10/10 microphone' "$test_log"
