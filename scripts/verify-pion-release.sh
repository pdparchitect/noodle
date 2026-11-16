#!/bin/zsh
# Checks a built Pion: its identity and version, no development hooks in a production build, its updater
# and Agent Host, and that it and Send to Pion are signed with exactly their entitlements in Incubator/Pion/Support.
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Pass the Pion app bundle}"
info="$app/Contents/Info.plist"
bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info")"
[[ "$bundle" == com.pdparchitect.pion || "$bundle" == com.pdparchitect.pion.local ]]
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info")" == "$(tr -d '[:space:]' < "$project_root/Incubator/Pion/VERSION")" ]]
# A development bundle carries development hooks; a production bundle must not.
if [[ "$bundle" == com.pdparchitect.pion ]]; then zsh "$project_root/scripts/verify-launch-hooks.sh" "$app"; fi
zsh "$project_root/scripts/verify-updater.sh" "$app"
zsh "$project_root/scripts/verify-agent-host.sh" "$app"
# The app and Send to Pion, each signed with exactly its file; the team prefixes their shared app group.
team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
signed="$(mktemp /tmp/pion-entitlements.XXXXXX)"
trap 'rm -f "$signed"' EXIT
for target in "${app}:Pion.entitlements" "${app}/Contents/PlugIns/PionShare.appex:ShareExtension.entitlements"; do
policy="$project_root/Incubator/Pion/Support/${target##*:}"
codesign -d --entitlements :- "${target%:*}" > "$signed" 2>/dev/null
python3 - "$signed" "$policy" "$bundle" "$team" <<'PY'
import plistlib, sys
signed, expected = (plistlib.load(open(path, 'rb')) for path in sys.argv[1:3])
bundle, team = sys.argv[3], sys.argv[4]
def fill(value):
    if isinstance(value, str):
        for name, filled in (('$(PRODUCT_BUNDLE_IDENTIFIER)', bundle), ('$(PION_APP_BUNDLE_ID)', bundle), ('$(TeamIdentifierPrefix)', team + '.')):
            value = value.replace(name, filled)
        return value
    if isinstance(value, list): return [fill(item) for item in value]
    if isinstance(value, dict): return {key: fill(item) for key, item in value.items()}
    return value
expected = fill(expected)
# A development build also carries the debugger's entitlement; a release never does.
if bundle.endswith('.local'): signed.pop('com.apple.security.get-task-allow', None)
if signed != expected:
    sys.exit(f'Pion entitlements differ from {sys.argv[2]}:\n{signed}')
PY
done
print "Pion bundle, identity, updater, Agent Host, Send to Pion and entitlements verified"
