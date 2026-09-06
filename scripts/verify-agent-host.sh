#!/bin/zsh
set -euo pipefail
app="${1:?Pass the built SuperBot.app path}"
host="$app/Contents/XPCServices/SuperBotAgentHost.xpc"
codesign --verify --strict "$host"
host_signature="$(codesign -dv --verbose=4 "$host" 2>&1)"
app_team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
host_team="$(print -r -- "$host_signature" | awk -F= '/^TeamIdentifier=/ { print $2 }')"
[[ "$app_team" == "$host_team" && "$app_team" =~ '^[A-Z0-9]{10}$' ]]
print -r -- "$host_signature" | grep -q 'runtime'
host_entitlements="$(codesign -d --entitlements :- "$host" 2>/dev/null)"
if print -r -- "$host_entitlements" | grep -q '<key>'; then
    print -u2 "The opt-in Agent Host must have no additional entitlements."
    exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SuperBotSigningTeam' "$host/Contents/Info.plist")" == "$app_team" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SuperBotSigningTeam' "$app/Contents/Info.plist")" == "$app_team" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$host/Contents/Info.plist")" == 'com.pdparchitect.superbot.agent-host' ]]
if otool -L "$host/Contents/MacOS/SuperBotAgentHost" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "Agent Host links a mutable external library."
    exit 1
fi
if otool -l "$host/Contents/MacOS/SuperBotAgentHost" | grep -Eq 'path .*(\.build|Xcode.*Toolchains)'; then
    print -u2 "Agent Host contains a development-only library search path."
    exit 1
fi
print "Opt-in Agent Host signature, identity, hardened runtime and zero entitlements verified"
