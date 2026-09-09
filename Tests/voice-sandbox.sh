#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
zsh "$project_root/Tests/voice-recording.sh"
fixture_app="$project_root/.build/Noodle Voice Tests.app"
mkdir -p "$fixture_app/Contents/MacOS" "$fixture_app/Contents/Resources"
cp "$project_root/.build/voice-recording-tests" "$fixture_app/Contents/MacOS/voice-recording-tests"
cp "$project_root/Tests/voice-sandbox-Info.plist" "$fixture_app/Contents/Info.plist"
say -o "$fixture_app/Contents/Resources/speech.aiff" 'Hello. This is a voice message. Please review the draft tomorrow.'
codesign --force --sign - --options runtime --entitlements "$project_root/Tests/voice-sandbox.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
# Synthetic file and live-buffer recognition inside App Sandbox. The fixture
# deliberately has no microphone entitlement and cannot record ambient audio.
"$fixture_app/Contents/MacOS/voice-recording-tests" --transcribe "$fixture_app/Contents/Resources/speech.aiff"
