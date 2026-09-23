#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --build-system native --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --build-system native --disable-sandbox --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")

swiftc -parse-as-library -package-name noodle -I "$bin_path/Modules" \
    "$project_root/Sources/NoodleRuntime/AgentRuntimeProcess.swift" \
    "$project_root/Sources/NoodleRuntime/CodexAgentProcess.swift" \
    "$project_root/Sources/NoodleRuntime/RuntimeShutdown.swift" \
    "$project_root/Sources/NoodleRuntime/HarnessRuntimeConnection.swift" \
    "$project_root/Sources/NoodleRuntime/ClaudeAgentProcess.swift" \
    "$project_root/Sources/NoodleRuntime/ACPAgentProcess.swift" \
    "$project_root/Sources/NoodleRuntime/MuseAgentProcess.swift" \
    "$project_root/Sources/NoodleRuntime/AntigravityAgentProcess.swift" \
    "$project_root/Sources/NoodleRuntime/MessageDeliveryClassifier.swift" \
    "$project_root/Sources/NoodleRuntime/MessageDeliveryRouter.swift" \
    "$project_root/Tests/message-delivery.swift" \
    "${core_objects[@]}" \
    -o "$project_root/.build/MessageDeliveryChecks"

if [[ "${1:-}" == "--classify" ]]; then
    # Exercise the native model inside App Sandbox without network, microphone,
    # file access, or any of the real app's data or harness accounts.
    fixture_app="$project_root/.build/Noodle Delivery Tests.app"
    mkdir -p "$fixture_app/Contents/MacOS"
    cp "$project_root/.build/MessageDeliveryChecks" "$fixture_app/Contents/MacOS/MessageDeliveryChecks"
    cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pdparchitect.noodle.delivery-tests</string>
<key>CFBundleExecutable</key><string>MessageDeliveryChecks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    cat > "$project_root/.build/delivery-test.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
    codesign --force --sign - --options runtime --entitlements "$project_root/.build/delivery-test.entitlements" "$fixture_app"
    codesign --verify --strict "$fixture_app"
    exec "$fixture_app/Contents/MacOS/MessageDeliveryChecks" --classify
fi
"$project_root/.build/MessageDeliveryChecks" "$@"
