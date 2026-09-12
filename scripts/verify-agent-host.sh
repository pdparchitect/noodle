#!/bin/zsh
set -euo pipefail
app="${1:?Pass the built Noodle.app path}"
host="$app/Contents/XPCServices/NoodleAgentHost.xpc"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:ServiceType' "$host/Contents/Info.plist")" == "Application" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :XPCService:JoinExistingSession' "$host/Contents/Info.plist")" == "true" ]]
codesign --verify --strict "$host"
host_signature="$(codesign -dv --verbose=4 "$host" 2>&1)"
app_team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
host_team="$(print -r -- "$host_signature" | awk -F= '/^TeamIdentifier=/ { print $2 }')"
[[ "$app_team" == "$host_team" && "$app_team" =~ '^[A-Z0-9]{10}$' ]]
print -r -- "$host_signature" | grep -q 'runtime'
host_entitlements="$(codesign -d --entitlements :- "$host" 2>/dev/null)"
if print -r -- "$host_entitlements" | grep -q '<key>'; then
    print -u2 "The Agent Host must have no additional entitlements."
    exit 1
fi
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NoodleSigningTeam' "$host/Contents/Info.plist")" == "$app_team" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NoodleSigningTeam' "$app/Contents/Info.plist")" == "$app_team" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$host/Contents/Info.plist")" == "$app_identifier.agent-host" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NoodleApplicationIdentifier' "$host/Contents/Info.plist")" == "$app_identifier" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NoodleAgentHostService' "$host/Contents/Info.plist")" == "$app_identifier.agent-host" ]]
if otool -L "$host/Contents/MacOS/NoodleAgentHost" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "Agent Host links a mutable external library."
    exit 1
fi
if otool -l "$host/Contents/MacOS/NoodleAgentHost" | grep -Eq 'path .*(\.build|Xcode.*Toolchains)'; then
    print -u2 "Agent Host contains a development-only library search path."
    exit 1
fi
print "Agent Host signature, identity, hardened runtime and zero entitlements verified"
apple_helper="$app/Contents/Helpers/NoodleAppleAgent"
codesign --verify --strict -R "=anchor apple generic and identifier \"$app_identifier.apple-agent\" and certificate leaf[subject.OU] = \"$app_team\"" "$apple_helper"
apple_signature="$(codesign -dv --verbose=4 "$apple_helper" 2>&1)"
print -r -- "$apple_signature" | grep -q 'runtime'
if codesign -d --entitlements :- "$apple_helper" 2>/dev/null | grep -q '<key>'; then
    print -u2 "The Apple harness must use the Agent Host policy without extra entitlements."
    exit 1
fi
if otool -L "$apple_helper" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "The Apple harness links a mutable external library."
    exit 1
fi
if otool -l "$apple_helper" | grep -Eq 'path .*(\.build|Xcode.*Toolchains)'; then
    print -u2 "The Apple harness contains a development-only library search path."
    exit 1
fi
print "Apple harness signature, bundled identity, hardened runtime and linkage verified"
