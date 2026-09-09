#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root"
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
fixture_app="$project_root/.build/Noodle MCP Window Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
objects=("${(@f)$(rg -v '/(Noodle|NoodleAgentBridge|NoodleSharing)\.build/' "$bin_path/Noodle.product/Objects.LinkFileList")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    -Xcc "-fmodule-map-file=$project_root/.build/checkouts/swift-system/Sources/CSystem/include/module.modulemap" \
    -Xcc "-I$project_root/.build/checkouts/swift-system/Sources/CSystem/include" \
    "$project_root/Sources/Noodle/MCPController.swift" \
    "$project_root/Sources/Noodle/ExternalEventPresentation.swift" \
    "$project_root/Tests/mcp-window-routing.swift" \
    "${objects[@]}" -o "$fixture_app/Contents/MacOS/MCPWindowFixture"
cp "$project_root/Tests/mcp-window-routing-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$project_root/Tests/mcp-window-routing.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
test_log="$(mktemp /tmp/noodle-mcp-window-check.XXXXXX)"
# Launch normally so the fixture's own URL scheme is registered with Launch Services.
open -W --stdout "$test_log" --stderr "$test_log" "$fixture_app" --args "${1:---check}"
cat "$test_log"
rg -q "MCP SwiftUI window routing checks passed" "$test_log"
