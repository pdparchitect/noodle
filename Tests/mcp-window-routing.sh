#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --build-system native --disable-sandbox --package-path "$project_root"
bin_path="$(swift build --build-system native --disable-sandbox --package-path "$project_root" --show-bin-path)"
fixture_app="$project_root/.build/Noodle MCP Window Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
objects=("${(@f)$(rg -v '/(Noodle|NoodleSharing)\.build/' "$bin_path/Noodle.product/Objects.LinkFileList")}")
swiftc -parse-as-library -I "$bin_path/Modules" \
    -Xcc "-fmodule-map-file=$project_root/.build/checkouts/swift-system/Sources/CSystem/include/module.modulemap" \
    -Xcc "-I$project_root/.build/checkouts/swift-system/Sources/CSystem/include" \
    "$project_root/Sources/Noodle/ExternalEventPresentation.swift" \
    "$project_root/Tests/mcp-window-routing.swift" \
    -F "$bin_path" -framework Sparkle -Xlinker -rpath -Xlinker "$bin_path" \
    "${objects[@]}" -o "$fixture_app/Contents/MacOS/MCPWindowFixture"
cp "$project_root/Tests/mcp-window-routing-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --entitlements "$project_root/Tests/mcp-window-routing.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
test_log="$(mktemp /tmp/noodle-mcp-window-check.XXXXXX)"
# Deliver launches and callbacks from outside the fixture, as the Dock and a
# browser do. Self-activation can be refused by macOS cooperative activation.
open -F -W --stdout "$test_log" --stderr "$test_log" "$fixture_app" --args "${1:---check}" &
fixture_launcher=$!
last_request=""
while kill -0 "$fixture_launcher" 2>/dev/null; do
    request="$(rg '^(REOPEN|CALLBACK) ' "$test_log" | tail -1 || true)"
    if [[ -n "$request" && "$request" != "$last_request" ]]; then
        last_request="$request"
        case "$request" in
            REOPEN\ *) open "$fixture_app" ;;
            CALLBACK\ *) open "${request#CALLBACK }" ;;
        esac
    fi
    sleep 0.1
done
wait "$fixture_launcher"
cat "$test_log"
rg -q "MCP SwiftUI window routing checks passed" "$test_log"
