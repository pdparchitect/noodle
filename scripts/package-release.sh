#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
expected_tag="v$version"
release_tag="${1:-${GITHUB_REF_NAME:-}}"
dist="$project_root/dist"
notary_input="$project_root/.release/Noodle-notarization.zip"
archive="$dist/Noodle-$version-macOS.zip"

if [[ -n "$release_tag" && "$release_tag" != "$expected_tag" ]]; then
    print -u2 "Release tag $release_tag does not match VERSION ($expected_tag)."
    exit 1
fi

: "${NOODLE_SIGNING_IDENTITY:?Set NOODLE_SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${APPLE_API_KEY_PATH:?Set APPLE_API_KEY_PATH to an App Store Connect API private key.}"
: "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID.}"
: "${APPLE_API_ISSUER_ID:?Set APPLE_API_ISSUER_ID.}"
: "${SPARKLE_PRIVATE_KEY_PATH:?Set SPARKLE_PRIVATE_KEY_PATH to the update-signing key file.}"

if [[ "$NOODLE_SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    print -u2 "NOODLE_SIGNING_IDENTITY must be a Developer ID Application identity."
    exit 1
fi

rm -rf "$dist" "$project_root/.release"
mkdir -p "$dist" "$project_root/.release"

export NOODLE_BUILD_CONFIGURATION=release
export NOODLE_BUILD_NUMBER="$version"
export NOODLE_DATA_CONTAINER=production
export NOODLE_CODESIGN_TIMESTAMP=1
export NOODLE_REQUIRE_DEVELOPER_ID=1
app="$("$project_root/scripts/build-app.sh")"

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" != "com.pdparchitect.noodle" ]]; then
    print -u2 "Release packaging must use the production data container identity."
    exit 1
fi

signature_info="$(codesign -dv --verbose=4 "$app" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<< "$signature_info"; then
    print -u2 "Noodle was not signed with a Developer ID Application certificate."
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app"
app_entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null | tr -d '[:space:]')"
entitlement_count="$(print -r -- "$app_entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
if [[ "$entitlement_count" != "7" ]] \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.files.user-selected.read-only</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.network.client</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key><array><string>/.codex/</string></array>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key><array><string>/.local/bin/claude</string><string>/.local/share/claude/versions/</string></array>'; then
    print -u2 "The signed app's sandbox entitlements do not match the reviewed seven-key policy."
    exit 1
fi

"$project_root/scripts/verify-sharing.sh" "$app"
zsh "$project_root/scripts/verify-updater.sh" "$app"
zsh "$project_root/scripts/verify-agent-host.sh" "$app"

helper_entitlements="$(codesign -d --entitlements :- "$app/Contents/Helpers/messenger" 2>/dev/null)"
if print -r -- "$helper_entitlements" | grep -q '<key>'; then
    print -u2 "The exported Messenger helper unexpectedly has application entitlements."
    exit 1
fi

if otool -L "$app/Contents/MacOS/Noodle" "$app/Contents/Helpers/messenger" | grep -Eq '/opt/homebrew|/usr/local'; then
    print -u2 "The exported app links against a mutable external dependency."
    exit 1
fi

ditto -c -k --sequesterRsrc --keepParent "$app" "$notary_input"

xcrun notarytool submit "$notary_input" \
    --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" \
    --issuer "$APPLE_API_ISSUER_ID" \
    --wait

xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
(
    cd "$dist"
    shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
)

# Sign the final stapled archive and the feed. Never change either after this step.
"$project_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
    --download-url-prefix "https://github.com/pdparchitect/noodle/releases/download/$expected_tag/" \
    --full-release-notes-url "https://github.com/pdparchitect/noodle/releases/tag/$expected_tag" \
    --maximum-deltas 0 \
    "$dist"
test -s "$dist/appcast.xml"
grep -q 'sparkle:edSignature=' "$dist/appcast.xml"
"$project_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$dist/appcast.xml"
archive_signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$dist/appcast.xml")"
"$project_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
    --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$archive" "$archive_signature"

print "$archive"
