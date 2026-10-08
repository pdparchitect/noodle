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
# The broker and live-demo checks are development hooks; a production bundle has neither.
if [[ "$identity" == com.pdparchitect.noodle.browser && ( -n "${NOODLE_BROWSER_TEST_NOODLE_APP:-}" || "${NOODLE_BROWSER_TEST_WEBMCP_DEMOS:-0}" == 1 ) ]]; then
    print -u2 'Use Dev bundles for the Noodle broker and live WebMCP demo checks.'; exit 1
fi
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
# Stop early if the server exits; allow a slow first Python launch on CI.
for _ in {1..300}; do [[ -s "$artifacts/port" ]] && break; kill -0 "$fixture_pid" 2>/dev/null || break; sleep 0.1; done
port="$(cat "$artifacts/port")"
[[ "$port" == <-> ]] || { print -u2 "Fixture server failed to start ($(python3 --version 2>&1), $(command -v python3))."; cat "$artifacts/server.log" >&2; exit 1; }
fixture_args=(--smoke-test --smoke-id "$smoke_id" --smoke-port "$port")
if [[ "${NOODLE_BROWSER_TEST_WEBMCP_DEMOS:-0}" == 1 ]]; then fixture_args+=(--webmcp-demos); fi
"$executable" "${fixture_args[@]}" > "$artifacts/browser.log" 2>&1 || { cat "$artifacts/browser.log"; exit 1; }
cat "$artifacts/browser.log"
profile_root="$HOME/Library/Containers/$identity/Data/Library/Application Support/BrowserSmoke/$smoke_id"
cp "$profile_root/screenshot.png" "$artifacts/screenshot.png"
cp "$profile_root/pointer.png" "$artifacts/pointer.png"
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
# An app outside Noodle, through the signed noodle-browser tool and its MCP server. A development hook
# answers the person's questions, so this needs the Dev bundle.
if [[ "${NOODLE_BROWSER_TEST_EXTERNAL:-0}" == 1 ]]; then
    [[ "$identity" == com.pdparchitect.noodle.browser.local ]] || { print -u2 'Use the Dev bundle for the external tools check.'; exit 1; }
    tool="$app/Contents/MacOS/noodle-browser"
    "$executable" "${fixture_args[@]}" --serve-external > "$artifacts/external.log" 2>&1 &
    browser_pid=$!
    for _ in {1..100}; do if grep -qx BROWSER_EXTERNAL_SERVER_READY "$artifacts/external.log"; then break; fi; sleep 0.1; done
    grep -qx BROWSER_EXTERNAL_SERVER_READY "$artifacts/external.log" || { cat "$artifacts/external.log"; exit 1; }
    json() { python3 -I -c "import json,sys; v=json.load(sys.stdin); print($1)"; }
    # The fixture's browsers were never lent, so the tool sees none of them.
    [[ "$("$tool" list | json 'len(v["browsers"])')" == 0 ]] || { print -u2 'The external tool saw browsers it was not lent.'; exit 1; }
    made="$("$tool" browser-create --name 'External check' | json 'v["browser"]["id"]')"
    "$tool" open --browser "$made" --url "http://127.0.0.1:$port/" > /dev/null
    for _ in {1..50}; do [[ "$("$tool" inspect --browser "$made" | json 'v["value"]["title"]')" == 'Browser verification' ]] && break; sleep 0.2; done
    [[ "$("$tool" inspect --browser "$made" | json 'v["value"]["title"]')" == 'Browser verification' ]] || { print -u2 'The external tool did not load the page.'; exit 1; }
    "$tool" screenshot --browser "$made" --output "$artifacts/external.png" > /dev/null
    [[ "$(file -b "$artifacts/external.png")" == PNG* ]] || { print -u2 'The external screenshot is not a PNG.'; exit 1; }
    print -r -- '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tabs","arguments":{"browser":"External check"}}}' |
        "$tool" mcp > "$artifacts/external-mcp.jsonl"
    python3 -I - "$artifacts/external-mcp.jsonl" <<'PY'
import json, sys
answers = {m["id"]: m for m in map(json.loads, open(sys.argv[1]))}
assert answers[1]["result"]["serverInfo"]["name"] == "noodle-browser"
names = {tool["name"] for tool in answers[2]["result"]["tools"]}
assert "browser-create" in names and "present" not in names and "browser-set-owner" not in names
assert not answers[3]["result"]["isError"] and len(answers[3]["result"]["structuredContent"]["tabs"]) == 1
PY
    "$tool" browser-delete --browser "$made" > /dev/null
    grep -q '^BROWSER_EXTERNAL_APPROVED ' "$artifacts/external.log" || { print -u2 'The caller was never asked about.'; exit 1; }
    kill "$browser_pid"; wait "$browser_pid" 2>/dev/null || true; browser_pid=''
    print 'PASS external tool: sees only its own browsers, drives a page, transfers a screenshot and serves MCP'
fi
"$executable" "${fixture_args[@]}" --restore > "$artifacts/restart.log" 2>&1 || { cat "$artifacts/restart.log"; exit 1; }
cat "$artifacts/restart.log"
"$executable" --smoke-test --cleanup --smoke-id "$smoke_id" --smoke-port "$port" > "$artifacts/cleanup.log" 2>&1 || { cat "$artifacts/cleanup.log"; exit 1; }
[[ ! -e "$profile_root" ]] || { print -u2 'Test profile cleanup did not complete.'; exit 1; }
port='' # The exit trap only needs to stop the fixture server now.
print "Browser verification artifacts: $artifacts"
