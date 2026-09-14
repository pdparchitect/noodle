#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
fixture_app="$project_root/.build/Destructive Button Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
swiftc -I "$bin_path/Modules" "$project_root/Sources/Noodle/DestructiveActionButton.swift" \
    "$project_root/Sources/Noodle/GroupMemberPicker.swift" \
    "$project_root/Tests/destructive-buttons.swift" "${core_objects[@]}" \
    -o "$fixture_app/Contents/MacOS/DestructiveButtons"
cp "$project_root/Tests/destructive-buttons-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$project_root/Tests/mcp-window-routing.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
"$fixture_app/Contents/MacOS/DestructiveButtons"
if [[ "${1:-}" == "--open" ]]; then open "$fixture_app" --args --open; fi
