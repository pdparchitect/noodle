#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:-$project_root/.build/Noodle Browser Dev.app}"
executable="$app/Contents/MacOS/NoodleBrowser"
identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
[[ "$identity" == com.pdparchitect.noodle.browser || "$identity" == com.pdparchitect.noodle.browser.local ]] || { print -u2 'Expected a Noodle Browser bundle.'; exit 1; }
fixture_id="$(uuidgen)"
root="$HOME/Library/Containers/$identity/Data/Library/Application Support/BrowserUI/$fixture_id"
artifacts="$project_root/.build/browser-ui-verification/$fixture_id"
mkdir -p "$artifacts"
cleanup() {
    for name in browser browser-page browser-collapsed browser-icon history bookmarks edit-browser settings updates research background new-browser empty-library; do
        if [[ -f "$root/$name.png" ]]; then cp "$root/$name.png" "$artifacts/$name.png"; fi
    done
    "$executable" --browser-ui-test --browser-ui-id "$fixture_id" --cleanup-ui > "$artifacts/cleanup.log" 2>&1 || true
}
trap cleanup EXIT
# The argument domain hides both entry points without touching saved preferences,
# so the toolbar's App Settings fallback is present for the placement check. The
# values must be property-list booleans; a bare NO arrives as a string.
"$executable" --browser-ui-test --browser-ui-id "$fixture_id" -showInDock '<false/>' -showMenuBar '<false/>' > "$artifacts/ui.log" 2>&1 || { cat "$artifacts/ui.log"; exit 1; }
for name in browser browser-page browser-collapsed browser-icon history bookmarks edit-browser settings updates research background new-browser empty-library; do
    cp "$root/$name.png" "$artifacts/$name.png"
done
cat "$artifacts/ui.log"
"$executable" --browser-ui-test --browser-ui-id "$fixture_id" --cleanup-ui > "$artifacts/cleanup.log" 2>&1 || { cat "$artifacts/cleanup.log"; exit 1; }
[[ ! -e "$root" ]] || { print -u2 'UI fixture cleanup failed.'; exit 1; }
trap - EXIT
print "Browser UI verification artifacts: $artifacts"
