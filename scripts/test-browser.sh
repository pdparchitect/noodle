#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:-$project_root/.build/Noodle Browser Dev.app}"
executable="$app/Contents/MacOS/NoodleBrowser"
[[ -x "$executable" ]] || { print -u2 'Build Noodle Browser first.'; exit 1; }
identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
case "$identity" in
    com.pdparchitect.noodle.browser.local) broker_identity=com.pdparchitect.noodle.local ;;
    com.pdparchitect.noodle.browser) broker_identity=com.pdparchitect.noodle ;;
    *) print -u2 'Expected a signed Noodle Browser app.'; exit 1 ;;
esac
smoke_id="$(uuidgen)"
artifacts="$project_root/.build/browser-verification/$smoke_id"
mkdir -p "$artifacts"
fixture_pid=''
browser_pid=''
port=''
cleanup() {
    if [[ -n "$browser_pid" ]]; then kill "$browser_pid" 2>/dev/null || true; wait "$browser_pid" 2>/dev/null || true; fi
    if [[ -n "$port" ]]; then "$executable" --smoke-test --cleanup --smoke-id "$smoke_id" --smoke-port "$port" > "$artifacts/cleanup.log" 2>&1 || true; fi
    if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
python3 "$project_root/Browser/Tests/Fixtures/server.py" > "$artifacts/port" 2> "$artifacts/server.log" &
fixture_pid=$!
for _ in {1..100}; do [[ -s "$artifacts/port" ]] && break; sleep 0.1; done
port="$(cat "$artifacts/port")"
[[ "$port" == <-> ]] || { print -u2 'Fixture server failed to start.'; exit 1; }
fixture_args=(--smoke-test --smoke-id "$smoke_id" --smoke-port "$port")
"$executable" "${fixture_args[@]}" > "$artifacts/browser.log" 2>&1 || { cat "$artifacts/browser.log"; exit 1; }
cat "$artifacts/browser.log"
profile_root="$HOME/Library/Containers/$identity/Data/Library/Application Support/BrowserSmoke/$smoke_id"
cp "$profile_root/screenshot.png" "$artifacts/screenshot.png"
cp "$profile_root/library.png" "$artifacts/library.png"
cp "$profile_root/history.png" "$artifacts/history.png"
cp "$profile_root/bookmarks.png" "$artifacts/bookmarks.png"
if [[ -n "${NOODLE_BROWSER_TEST_NOODLE_APP:-}" ]]; then
    actual_broker_identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$NOODLE_BROWSER_TEST_NOODLE_APP/Contents/Info.plist")"
    [[ "$actual_broker_identity" == "$broker_identity" ]] || { print -u2 'Use matching Dev or normal Noodle and Browser builds.'; exit 1; }
    broker="$NOODLE_BROWSER_TEST_NOODLE_APP/Contents/MacOS/Noodle"
    [[ -x "$broker" ]] || { print -u2 'Noodle test bundle not found.'; exit 1; }
    browser_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["profiles"][0]["id"])' "$profile_root/browsers.json")"
    "$executable" "${fixture_args[@]}" --serve-smoke > "$artifacts/provider.log" 2>&1 &
    browser_pid=$!
    for _ in {1..100}; do if rg -q '^BROWSER_SMOKE_SERVER_READY$' "$artifacts/provider.log"; then break; fi; sleep 0.1; done
    rg -q '^BROWSER_SMOKE_SERVER_READY$' "$artifacts/provider.log" || { cat "$artifacts/provider.log"; exit 1; }
    "$broker" --browser-integration-test --browser-fixture "$browser_id" --browser-fixture-port "$port" > "$artifacts/broker.log" 2>&1 || { cat "$artifacts/broker.log"; exit 1; }
    cat "$artifacts/broker.log"
    kill "$browser_pid"; wait "$browser_pid" 2>/dev/null || true; browser_pid=''
fi
"$executable" "${fixture_args[@]}" --restore > "$artifacts/restart.log" 2>&1 || { cat "$artifacts/restart.log"; exit 1; }
cat "$artifacts/restart.log"
"$executable" --smoke-test --cleanup --smoke-id "$smoke_id" --smoke-port "$port" > "$artifacts/cleanup.log" 2>&1 || { cat "$artifacts/cleanup.log"; exit 1; }
[[ ! -e "$profile_root" ]] || { print -u2 'Test profile cleanup did not complete.'; exit 1; }
port='' # The exit trap only needs to stop the fixture server now.
print "Browser verification artifacts: $artifacts"
