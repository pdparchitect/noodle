#!/bin/zsh
# A release app carries no development hooks and names no launch check.
# Development hooks are compiled in only under NOODLE_DEV_HOOKS, which also compiles in the marker below.
# Launch checks that stay in a release are matched by digest; see Shared/LaunchChecks.
set -euo pipefail
if [[ "${NOODLE_VERIFY_VERBOSE:-0}" == 1 ]]; then set -x; fi
app="${1:?Pass the built app or its executable}"
executable="$app"
if [[ -d "$app" ]]; then
    executable="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
fi
[[ -f "$executable" ]] || { print -u2 "Missing executable: $executable"; exit 1; }
found="$(strings -a "$executable" | grep -E -- 'noodle\.development-hooks\.enabled|^--[a-z0-9-]+-(test|preview|check)$|^--(self-test|smoke-test|cleanup-ui|keep-test-window|webmcp-only|browser-fixture|browser-fixture-port|scenario)$' | sort -u || true)"
if [[ -n "$found" ]]; then
    print -u2 "Development hooks or launch check names found in $executable:"
    print -u2 -r -- "$found"
    exit 1
fi
