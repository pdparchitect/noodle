#!/bin/zsh
set -euo pipefail
source_root="${0:A:h}"
swift build --disable-sandbox --package-path "$source_root" --product ComputerBridgeProbe >&2
bin_path="$(swift build --disable-sandbox --package-path "$source_root" --show-bin-path)"
proof_root="$(mktemp -d /tmp/noodle-bridge-proof.XXXXXX)"
proof_identity="${NOODLE_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')}"
[[ -n "$proof_identity" ]]
for role in server client rejected; do
    bundle="$proof_root/$role.app"
    mkdir -p "$bundle/Contents/MacOS"
    cp "$bin_path/ComputerBridgeProbe" "$bundle/Contents/MacOS/Probe"
    codesign --force --timestamp=none --sign "$proof_identity" "$bundle/Contents/MacOS/Probe" >&2
    team="$(codesign -dv --verbose=4 "$bundle/Contents/MacOS/Probe" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
    [[ "$team" =~ '^[A-Z0-9]{10}$' ]]
    group="$team.com.pdparchitect.noodle.bridgeproof"
    plist="$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Clear dict' "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.pdparchitect.noodle.bridgeproof.$role" "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Probe' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$plist"
    /usr/libexec/PlistBuddy -c "Add :NoodleSigningTeam string $team" "$plist"
    /usr/libexec/PlistBuddy -c "Add :NoodleComputerGroup string $group" "$plist"
    entitlement="$proof_root/$role.entitlements"
    /usr/libexec/PlistBuddy -c 'Clear dict' "$entitlement" >/dev/null
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$entitlement"
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$entitlement"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $group" "$entitlement"
    codesign --force --options runtime --timestamp=none --entitlements "$entitlement" --sign "$proof_identity" "$bundle" >&2
    codesign --verify --strict "$bundle"
done
"$proof_root/server.app/Contents/MacOS/Probe" server > "$proof_root/server.log" 2>&1 &
proof_pid=$!
trap 'kill "$proof_pid" 2>/dev/null || true' EXIT
for attempt in {1..30}; do
    if rg -q READY "$proof_root/server.log"; then break; fi
    if ! kill -0 "$proof_pid" 2>/dev/null; then
        cat "$proof_root/server.log"; exit 1
    fi
    sleep 0.2
done
"$proof_root/client.app/Contents/MacOS/Probe" client
if "$proof_root/rejected.app/Contents/MacOS/Probe" client; then
    print -u2 'FAIL: unrecognized client was accepted'; exit 1
fi
print "PASS: unrecognized client rejected. Fixtures: $proof_root"
