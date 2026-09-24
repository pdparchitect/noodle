#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

module_cache="$project_root/.build/module-cache"
mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

swift test --disable-sandbox --package-path "$project_root"
swift test --disable-sandbox --package-path "$project_root/Shared/Wallpaper" --scratch-path "$project_root/.build/wallpaper"
swift test --disable-sandbox --package-path "$project_root/Shared/SettingsUI" --scratch-path "$project_root/.build/settings-ui"
zsh "$project_root/Tests/message-delivery.sh"
zsh "$project_root/Tests/scrollable-composer.sh"
zsh "$project_root/Tests/voice-shortcut.sh"
zsh "$project_root/Tests/voice-composer.sh"
zsh "$project_root/Tests/link-previews.sh"
zsh "$project_root/Tests/harness-presentation.sh"
zsh "$project_root/Tests/transcript-resize.sh"
zsh "$project_root/Tests/transcript-startup.sh"
zsh "$project_root/Tests/message-reader-annotations.sh"
zsh "$project_root/Tests/mcp-fixture.sh" --check
zsh "$project_root/Tests/mcp-window-routing.sh"
zsh "$project_root/Tests/destructive-buttons.sh"
app="$(zsh "$project_root/scripts/xcode-build.sh" Noodle)"

expected_version="$(tr -d '[:space:]' < "$project_root/VERSION")"
actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [[ "$actual_version" != "$expected_version" ]]; then
    print -u2 "Built app version $actual_version does not match VERSION ($expected_version)."
    exit 1
fi
actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
if [[ "$actual_build" != "$expected_version" ]]; then
    print -u2 "Built app's update version does not match VERSION."
    exit 1
fi

expected_identifier="com.pdparchitect.noodle.local"
if [[ "${NOODLE_DATA_CONTAINER:-development}" == "production" ]]; then
    expected_identifier="com.pdparchitect.noodle"
fi
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
if [[ "$actual_identifier" != "$expected_identifier" ]]; then
    print -u2 "Built app uses $actual_identifier instead of the requested $expected_identifier data container."
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$app/Contents/Helpers/messenger"
# Messenger is the one command bots run for every tool, including scripts against tool connections.
messenger_entitlements="$(codesign -d --entitlements :- "$app/Contents/Helpers/messenger" 2>/dev/null)"
if print -r -- "$messenger_entitlements" | grep -q '<key>'; then
    print -u2 "Messenger must not inherit application entitlements."
    exit 1
fi
[[ ! -e "$app/Contents/Helpers/mcpshim" ]] || { print -u2 "The removed mcpshim helper is still bundled."; exit 1; }
if otool -L "$app/Contents/Helpers/messenger" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "Messenger links against a mutable external dependency."
    exit 1
fi
test -f "$app/Contents/Resources/swift-sdk-LICENSE.txt"
for icon in "$project_root"/Support/ToolIcons/*.icon; do
    cmp "$icon" "$app/Contents/Resources/ToolIcons/${icon:t}"
done

helper_entitlements="$(codesign -d --entitlements :- "$app/Contents/Helpers/messenger" 2>/dev/null)"
if print -r -- "$helper_entitlements" | grep -q '<key>'; then
    print -u2 "The Messenger helper must not inherit application entitlements."
    exit 1
fi

if [[ ! -x "$app/Contents/Helpers/messenger" ]]; then
    print -u2 "Bundled Messenger helper is missing or not executable."
    exit 1
fi

intent_metadata="$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [[ ! -f "$intent_metadata" ]]; then
    print -u2 "App Intents metadata is missing from the bundle."
    exit 1
fi

if ! grep -q 'SendNoodleCommandIntent' "$intent_metadata"; then
    print -u2 "The Send to Agent intent is missing from App Intents metadata."
    exit 1
fi

if ! xcrun assetutil --info "$app/Contents/Resources/Assets.car" | grep -q '"Name" : "CodexHarness"'; then
    print -u2 "The official Codex harness icon is missing from the asset catalogue."
    exit 1
fi

if ! xcrun assetutil --info "$app/Contents/Resources/Assets.car" | grep -q '"Name" : "ClaudeHarness"'; then
    print -u2 "The official Claude harness icon is missing from the asset catalogue."
    exit 1
fi

if ! xcrun assetutil --info "$app/Contents/Resources/Assets.car" | grep -q '"Name" : "GrokHarness"'; then
    print -u2 "The Grok Build template icon is missing from the asset catalogue."
    exit 1
fi

if ! xcrun assetutil --info "$app/Contents/Resources/Assets.car" | grep -q '"Name" : "FxHarness"'; then
    print -u2 "The FX template icon is missing from the asset catalogue."
    exit 1
fi

entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
# The Dev app is a debug build, which the debugger may attach to; that entitlement is not part of the policy.
compact_entitlements="$(print -r -- "$entitlements" | tr -d '[:space:]' | sed 's|<key>com.apple.security.get-task-allow</key><true/>||')"
entitlement_count="$(print -r -- "$compact_entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
if [[ "$entitlement_count" != "10" ]]; then
    print -u2 "The app must contain exactly the ten reviewed sandbox entitlements."
    exit 1
fi
zsh "$project_root/scripts/verify-updater.sh" "$app"
zsh "$project_root/scripts/verify-agent-host.sh" "$app"
swift "$project_root/Tests/agent-host-startup.swift" "$app/Contents/XPCServices/NoodleAgentHost.xpc/Contents/MacOS/NoodleAgentHost"
if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>'; then
    print -u2 "App Sandbox entitlement is missing."
    exit 1
fi

if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.files.user-selected.read-only</key><true/>'; then
    print -u2 "User-selected read-only file entitlement is missing."
    exit 1
fi

if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.network.client</key><true/>'; then
    print -u2 "Outgoing network entitlement is missing."
    exit 1
fi

if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key><array><string>/.codex/</string></array>'; then
    print -u2 "The narrow Codex state-directory exception is missing or broader than expected."
    exit 1
fi

# Whitespace is stripped above, so "Application Support" appears without its space.
if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key><array><string>/.local/bin/claude</string><string>/.local/share/claude/versions/</string><string>/.local/bin/fx</string><string>/Library/ApplicationSupport/com.apple.mobileAssetDesktop/</string><string>/Library/ApplicationSupport/com.apple.wallpaper/aerials/</string></array>'; then
    print -u2 "The narrow Claude Code / FX executable and downloaded system wallpaper exceptions are missing or broader than expected."
    exit 1
fi

if otool -L "$app/Contents/MacOS/Noodle" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "The app links against a mutable external dependency."
    exit 1
fi

if otool -L "$app/Contents/Helpers/messenger" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "The Messenger helper links against a mutable external dependency."
    exit 1
fi

print "Noodle smoke tests passed"
"$project_root/scripts/verify-sharing.sh" "$app"
