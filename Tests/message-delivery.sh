#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"

# Compile the production Codex adapter and runtime protocol without the app's
# discovery/UI coordinator. Other adapters already live in separate files.
python3 - "$project_root" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
source = (root / 'Sources/Noodle/AgentRuntimeCoordinator.swift').read_text()
protocol = source[source.index('@MainActor\nprotocol AgentRuntimeProcess'):source.index('@MainActor\n@Observable')]
adapter = source[source.index('@MainActor\nfinal class CodexAgentProcess'):source.index('@MainActor\nprivate final class CodexCapabilityProbe')]
header = 'import Darwin\nimport Foundation\nimport NoodleCore\nprivate let noodleAppVersion = "fixture"\nprivate enum HostEnvironment { static let codexHome = FileManager.default.temporaryDirectory }\n'
(root / '.build/DeliveryCodexAdapter.swift').write_text(header + protocol + adapter)
PY

swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/.build/DeliveryCodexAdapter.swift" \
    "$project_root/Sources/Noodle/ClaudeAgentProcess.swift" \
    "$project_root/Sources/Noodle/ACPAgentProcess.swift" \
    "$project_root/Sources/Noodle/MuseAgentProcess.swift" \
    "$project_root/Sources/Noodle/MessageDeliveryClassifier.swift" \
    "$project_root/Sources/Noodle/MessageDeliveryRouter.swift" \
    "$project_root/Tests/message-delivery.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o "$bin_path"/AppletBridge.build/*.swift.o \
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
