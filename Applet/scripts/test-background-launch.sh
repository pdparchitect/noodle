#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h:h}"
provider="$project_root/.build/Noodle Applet.app"
provider_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$provider/Contents/Info.plist")
staging=$(mktemp -d "$project_root/.build/BackgroundLaunch.XXXXXX")
trap 'rm -rf "$staging"' EXIT
sender="$staging/SandboxedLaunchTest.app"
mkdir -p "$sender/Contents/MacOS"
cat > "$sender/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pdparchitect.noodle.applet.launchsender</string>
<key>CFBundleExecutable</key><string>LaunchTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
cat > "$staging/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
EOF
swiftc -parse-as-library "$project_root/Applet/Protocol/Sources/AppletBridge/AppletLaunch.swift" \
    "$project_root/Applet/Tests/BackgroundLaunch.swift" -o "$sender/Contents/MacOS/LaunchTest"
identity=$(codesign -dv --verbose=4 "$provider" 2>&1 | sed -n 's/^Authority=//p' | head -1)
codesign --force --options runtime --timestamp=none --sign "$identity" \
    --entitlements "$staging/entitlements.plist" "$sender"
codesign --verify --deep --strict "$sender"
codesign -d --entitlements :- "$sender" > "$staging/signed-entitlements.plist" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$staging/signed-entitlements.plist")" == true ]]
result=0
"$sender/Contents/MacOS/LaunchTest" "$provider_id" "$provider" "$@" > "$staging/output.log" 2>&1 || result=$?
cat "$staging/output.log"
# A sandboxed caller cannot reliably terminate the provider. Clean up only the
# process this fixture launched, after checking that its executable still matches.
test_pid=$(sed -n 's/^Launched test Applet PID \([0-9][0-9]*\)$/\1/p' "$staging/output.log")
if [[ -n "$test_pid" && "$(ps -p "$test_pid" -o comm=)" == "$provider/Contents/MacOS/NoodleApplet" ]]; then
    kill -TERM "$test_pid"
fi
exit "$result"
