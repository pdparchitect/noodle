#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
fixture_app="$project_root/.build/Chat Feature Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
swiftc -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/BotAvatar.swift" \
    "$project_root/Sources/Noodle/MessageMarkdownCache.swift" \
    "$project_root/Sources/Noodle/SheetSizing.swift" \
    "$project_root/Sources/Noodle/ComposerNameCompletion.swift" \
    "$project_root/Sources/Noodle/ComposerAttachmentMenu.swift" \
    "$project_root/Sources/Noodle/AgentProfileSheet.swift" \
    "$project_root/Tests/chat-features.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o \
    -o "$fixture_app/Contents/MacOS/ChatFeaturesTest"
cp "$project_root/Tests/chat-features-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$project_root/Tests/chat-features.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
"$fixture_app/Contents/MacOS/ChatFeaturesTest" --verify
open "$fixture_app"
