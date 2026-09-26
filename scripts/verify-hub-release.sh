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
zsh "$project_root/scripts/verify-updater.sh" "$app"
zsh "$project_root/scripts/verify-agent-host.sh" "$app"
# The signed app holds exactly Hub/Support/Hub.entitlements, with its bundle identifier, team and
# Computer pairing filled in.
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
suffix=""; [[ "$bundle" == *.local ]] && suffix=".local"
signed="$(mktemp /tmp/hub-entitlements.XXXXXX)"
trap 'rm -f "$signed"' EXIT
codesign -d --entitlements :- "$app" > "$signed" 2>/dev/null
python3 - "$signed" "$project_root/Hub/Support/Hub.entitlements" "$bundle" "$team" "$suffix" <<'PY'
import plistlib, sys
signed, expected = (plistlib.load(open(path, 'rb')) for path in sys.argv[1:3])
bundle, team, suffix = sys.argv[3:6]
def fill(value):
    if isinstance(value, str):
        return (value.replace('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle).replace('$(TeamIdentifierPrefix)', team + '.')
                .replace('$(HUB_COMPANION_SUFFIX)', suffix))
    if isinstance(value, list): return [fill(item) for item in value]
    if isinstance(value, dict): return {key: fill(item) for key, item in value.items()}
    return value
expected = fill(expected)
if signed != expected:
    sys.exit(f'Hub entitlements differ from Hub/Support/Hub.entitlements:\n{signed}')
PY
print "Hub bundle, identity, updater, Agent Host and entitlements verified"
