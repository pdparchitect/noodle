#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root"
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
app="$project_root/.build/Noodle MCP Tests.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers"
objects=("${(@f)$(rg -v '/(Noodle|NoodleAgentBridge|NoodleSharing)\.build/' "$bin_path/Noodle.product/Objects.LinkFileList")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    -Xcc "-fmodule-map-file=$project_root/.build/checkouts/swift-system/Sources/CSystem/include/module.modulemap" \
    -Xcc "-I$project_root/.build/checkouts/swift-system/Sources/CSystem/include" \
    "$project_root/Sources/Noodle/MCPController.swift" \
    "$project_root/Sources/Noodle/ExternalEventPresentation.swift" \
    "$project_root/Sources/Noodle/MCPSettingsView.swift" \
    "$project_root/Sources/Noodle/ToolCatalogView.swift" \
    "$project_root/Sources/Noodle/SheetSizing.swift" \
    "$project_root/Tests/mcp-fixture.swift" \
    "${objects[@]}" -o "$app/Contents/MacOS/MCPFixture"
cp "$project_root/Tests/mcp-fixture-Info.plist" "$app/Contents/Info.plist"
ditto "$project_root/Support/ToolIcons" "$app/Contents/Resources/ToolIcons"
cp "$bin_path/NoodleMCPCLI" "$app/Contents/Helpers/mcpshim"
cp "$bin_path/NoodleMessenger" "$app/Contents/Helpers/messenger"
identity="${NOODLE_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')}"
if [[ -z "$identity" ]]; then
    print -u2 "An Apple Development signing identity is required to test native OAuth and Keychain."
    exit 1
fi
codesign --force --options runtime --timestamp=none --sign "$identity" "$app/Contents/Helpers/mcpshim"
codesign --force --options runtime --timestamp=none --sign "$identity" "$app/Contents/Helpers/messenger"
codesign --force --options runtime --timestamp=none --sign "$identity" \
    --entitlements "$project_root/Tests/mcp-fixture.entitlements" "$app"
codesign --verify --deep --strict "$app"
print "Built isolated MCP fixture: $app"
if [[ "${1:-}" == "--open" ]]; then open "$app"; fi
if [[ "${1:-}" == "--check" ]]; then "$app/Contents/MacOS/MCPFixture" --check; fi
if [[ "${1:-}" == "--check-live" ]]; then "$app/Contents/MacOS/MCPFixture" --check-live; fi
