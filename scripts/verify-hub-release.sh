#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Hub app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.noodle.hub || "$bundle" == com.pdparchitect.noodle.hub.local ]]
codesign --verify --deep --strict "$app"
cmp "$project_root/Hub/Support/AppSymbol.svg" "$app/Contents/Resources/AppSymbol.svg"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$(tr -d '[:space:]' < "$project_root/Hub/VERSION")" ]]
# The Hub lives in the menu bar only.
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info")" == true ]]
# A development bundle carries development hooks; a production bundle must not.
if [[ "$bundle" == com.pdparchitect.noodle.hub ]]; then zsh "$project_root/scripts/verify-launch-hooks.sh" "$app"; fi
zsh "$project_root/scripts/verify-agent-host.sh" "$app"
# The signed app holds exactly the entitlements in Hub/Support/Hub.entitlements.
signed="$(mktemp /tmp/hub-entitlements.XXXXXX)"
trap 'rm -f "$signed"' EXIT
codesign -d --entitlements :- "$app" > "$signed" 2>/dev/null
python3 - "$signed" "$project_root/Hub/Support/Hub.entitlements" <<'PY'
import plistlib, sys
signed, expected = (plistlib.load(open(path, 'rb')) for path in sys.argv[1:])
if signed != expected:
    sys.exit(f'Hub entitlements differ from Hub/Support/Hub.entitlements:\n{signed}')
PY
print "Hub bundle, identity, Agent Host and entitlements verified"
