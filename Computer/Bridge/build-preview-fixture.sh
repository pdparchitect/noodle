#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h:h}"
fixture_root="$(mktemp -d /tmp/noodle-interaction-test.XXXXXX)"
fixture_app="$fixture_root/Noodle Integration.app"
cp -R "$project_root/.build/Noodle Local.app" "$fixture_app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.pdparchitect.noodle.integration' "$fixture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Noodle Integration' "$fixture_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Noodle Integration' "$fixture_app/Contents/Info.plist" 2>/dev/null || true
identity="${NOODLE_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')}"
[[ -n "$identity" ]]
codesign --force --options runtime --timestamp=none --entitlements "$project_root/.build/Noodle.resolved.entitlements" --sign "$identity" "$fixture_app" >&2
codesign --verify --deep --strict "$fixture_app"
print "$fixture_app"
