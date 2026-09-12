#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
swift build --disable-sandbox --package-path "$project_root" --target NoodleAudioCapture
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
fixture_app="$project_root/.build/Noodle Voice Shortcut Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
swiftc -parse-as-library -I "$bin_path/Modules" \
    -I "$project_root/Sources/NoodleAudioCapture/include" \
    -Xcc -fmodule-map-file="$bin_path/NoodleAudioCapture.build/module.modulemap" \
    "$project_root/Sources/Noodle/KeyboardBindings.swift" \
    "$project_root/Sources/Noodle/AnnotationCommands.swift" \
    "$project_root/Sources/Noodle/VoiceRecorder.swift" \
    "$project_root/Sources/Noodle/VoiceCaptureRecovery.swift" \
    "$project_root/Sources/Noodle/VoiceInputDevice.swift" \
    "$project_root/Sources/Noodle/VoiceRecordingCommand.swift" \
    "$project_root/Tests/NativeFixtureChecks.swift" \
    "$project_root/Tests/voice-shortcut.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o \
    "$bin_path"/NoodleAudioCapture.build/*.o \
    -o "$fixture_app/Contents/MacOS/VoiceShortcutTests"
cp "$project_root/Tests/voice-shortcut-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$project_root/Tests/voice-shortcut.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
codesign -d --entitlements :- "$fixture_app"
if otool -L "$fixture_app/Contents/MacOS/VoiceShortcutTests" | rg -q '/opt/homebrew|/usr/local'; then
    print -u2 "The fixture must not link against mutable external libraries."
    exit 1
fi
test_log="$(mktemp /tmp/noodle-voice-shortcut.XXXXXX)"
trap 'rm -f "$test_log"' EXIT
open -W --stdout "$test_log" --stderr "$test_log" "$fixture_app"
cat "$test_log"
rg -q '^(PASS: ⌘⇧D|SKIP: voice recording requires macOS 26)' "$test_log"
