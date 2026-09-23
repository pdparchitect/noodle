#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleRuntimeSettings
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path" NoodleRuntimeSettings NoodleRuntime NoodleAgentBridge NoodleSettingsUI NoodleWallpaper)}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/ComposerNameCompletion.swift" \
    "$project_root/Sources/Noodle/ScrollableChatComposer.swift" \
    "$project_root/Sources/Noodle/ConversationListKeyboardNavigation.swift" \
    "$project_root/Tests/conversation-keyboard.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/ConversationKeyboardChecks"
"$project_root/.build/ConversationKeyboardChecks"
