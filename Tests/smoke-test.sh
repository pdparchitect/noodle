#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"

module_cache="$project_root/.build/module-cache"
mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

swift test --disable-sandbox --package-path "$project_root"
app="$(SUPERBOT_BUILD_CONFIGURATION=debug "$project_root/scripts/build-app.sh")"

codesign --verify --deep --strict --verbose=2 "$app"

entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)"
compact_entitlements="$(print -r -- "$entitlements" | tr -d '[:space:]')"
if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>'; then
    print -u2 "App Sandbox entitlement is missing."
    exit 1
fi

if ! print -r -- "$compact_entitlements" | grep -q '<key>com.apple.security.files.user-selected.read-only</key><true/>'; then
    print -u2 "User-selected read-only file entitlement is missing."
    exit 1
fi

if otool -L "$app/Contents/MacOS/SuperBot" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "The app links against a mutable external dependency."
    exit 1
fi

print "SuperBot smoke tests passed"
