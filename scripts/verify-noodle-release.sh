#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Noodle app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.noodle || "$bundle" == com.pdparchitect.noodle.local ]]
codesign --verify --deep --strict "$app"
[[ "$(lipo -archs "$app/Contents/MacOS/Noodle")" == arm64 ]] || { print -u2 'Noodle ships for Apple silicon only.'; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$(tr -d '[:space:]' < "$project_root/VERSION")" ]]
# A development bundle carries development hooks; a production bundle must not.
if [[ "$bundle" == com.pdparchitect.noodle ]]; then zsh "$project_root/scripts/verify-launch-hooks.sh" "$app"; fi

app_entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null | tr -d '[:space:]')"
# Whitespace is stripped above, so "Application Support" appears without its space.
entitlement_count="$(print -r -- "$app_entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
if [[ "$entitlement_count" != "11" ]] \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.files.user-selected.read-only</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.network.client</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.device.audio-input</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.device.camera</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.personal-information.calendars</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.personal-information.reminders</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key><array><string>/.codex/</string></array>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key><array><string>/.local/bin/claude</string><string>/.local/share/claude/versions/</string><string>/.local/bin/fx</string><string>/Library/ApplicationSupport/com.apple.mobileAssetDesktop/</string><string>/Library/ApplicationSupport/com.apple.wallpaper/aerials/</string></array>'; then
    print -u2 "The signed app's sandbox entitlements do not match the reviewed eleven-key policy."
    exit 1
fi

zsh "$project_root/scripts/verify-sharing.sh" "$app"
zsh "$project_root/scripts/verify-updater.sh" "$app"
zsh "$project_root/scripts/verify-agent-host.sh" "$app"
zsh "$project_root/scripts/verify-tool-extensions.sh" "$app"

if codesign -d --entitlements :- "$app/Contents/Helpers/messenger" 2>/dev/null | grep -q '<key>'; then
    print -u2 "The exported Messenger helper unexpectedly has application entitlements."
    exit 1
fi
if otool -L "$app/Contents/MacOS/Noodle" "$app/Contents/Helpers/messenger" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "The exported app links against a mutable external dependency."
    exit 1
fi
swift "$project_root/Tests/agent-host-startup.swift" "$app/Contents/XPCServices/NoodleAgentHost.xpc/Contents/MacOS/NoodleAgentHost"
# Shortcuts finds the Send to Agent intent in the app's metadata.
grep -q SendNoodleCommandIntent "$app/Contents/Resources/Metadata.appintents/extract.actionsdata" ||
    { print -u2 "The Send to Agent intent is missing from App Intents metadata."; exit 1; }
assets="$(xcrun assetutil --info "$app/Contents/Resources/Assets.car")"
for icon in CodexHarness ClaudeHarness GrokHarness FxHarness; do
    print -r -- "$assets" | grep -q "\"Name\" : \"$icon\"" || { print -u2 "The $icon icon is missing from the asset catalogue."; exit 1; }
done
for icon in "$project_root"/Support/ToolIcons/*.icon; do cmp "$icon" "$app/Contents/Resources/ToolIcons/${icon:t}"; done
[[ -f "$app/Contents/Resources/swift-sdk-LICENSE.txt" ]] || { print -u2 "Dependency licences are missing."; exit 1; }
# Local models need the Apple helper built with the macOS 27 SDK and MLX's compiled shaders.
[[ "$("$app/Contents/Helpers/NoodleAppleAgent" --build-capabilities | plutil -extract apple27 raw -o - -)" == true ]] ||
    { print -u2 "The Apple helper was not compiled with the macOS 27 SDK."; exit 1; }
[[ -s "$app/Contents/Helpers/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]] ||
    { print -u2 "Local model support requires compiled MLX Metal shaders."; exit 1; }
print "Noodle bundle, identity, sandbox policy, sharing, updater, Agent Host, tool extensions and helpers verified"
