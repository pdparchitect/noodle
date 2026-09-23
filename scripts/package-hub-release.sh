#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/Hub/VERSION")"
tag="hub-v$version"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Hub/VERSION'; exit 1; }
[[ "${1:-}" == "$tag" ]] || { print -u2 "Expected release tag $tag"; exit 1; }
grep -Eq "^## \\[$version\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$project_root/Hub/CHANGELOG.md" || {
    print -u2 'Hub release notes are not approved and dated.'; exit 1
}
: "${NOODLE_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${APPLE_API_KEY_PATH:?Set the notarization key path}"
: "${APPLE_API_KEY_ID:?Set the notarization key ID}"
: "${APPLE_API_ISSUER_ID:?Set the notarization issuer ID}"
: "${SPARKLE_PRIVATE_KEY_PATH:?Set the update-signing key path}"
[[ "$NOODLE_SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || { print -u2 'Developer ID required'; exit 1; }

# Only new, product-specific generated output; never erase other release assets.
mkdir -p "$project_root/.release" "$project_root/dist"
staging="$(mktemp -d "$project_root/.release/hub.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output="$project_root/dist/hub-$version"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Public Hub archives require Apple silicon.'; exit 1; }
export NOODLE_HUB_CONFIGURATION=release NOODLE_HUB_DATA_CONTAINER=production
export NOODLE_REQUIRE_DEVELOPER_ID=1 NOODLE_CODESIGN_TIMESTAMP=1
app="$(zsh "$project_root/scripts/build-hub.sh")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.hub ]]
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'
zsh "$project_root/scripts/verify-hub-release.sh" "$app"
zsh "$project_root/scripts/verify-launch-hooks.sh" "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/notary.zip"
xcrun notarytool submit "$staging/notary.zip" --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
mkdir "$staging/assets"
archive="Noodle-Hub-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/assets/$archive"
(cd "$staging/assets"; shasum -a 256 "$archive" > "$archive.sha256")
sparkle_tools="$project_root/.build/hub/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
    --download-url-prefix "https://github.com/pdparchitect/noodle/releases/download/$tag/" \
    --full-release-notes-url "https://github.com/pdparchitect/noodle/releases/tag/$tag" \
    --maximum-deltas 0 "$staging/assets"
"$sparkle_tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$staging/assets/appcast.xml"
archive_signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$staging/assets/appcast.xml")"
[[ -n "$archive_signature" ]]
"$sparkle_tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$staging/assets/$archive" "$archive_signature"
# Build after generate_appcast so Sparkle continues to use only the ZIP.
zsh "$project_root/scripts/package-dmg.sh" "$app" "$staging/assets/${archive:r}.dmg"
mv "$staging/assets" "$output"
print "$output"
