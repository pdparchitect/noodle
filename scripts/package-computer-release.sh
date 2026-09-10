#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/Computer/VERSION")"
tag="computer-v$version"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Computer/VERSION'; exit 1; }
[[ "${1:-}" == "$tag" ]] || { print -u2 "Expected release tag $tag"; exit 1; }
grep -Eq "^## \\[$version\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$project_root/Computer/CHANGELOG.md" || {
    print -u2 'Computer release notes are not approved and dated.'; exit 1
}
: "${NOODLE_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
: "${APPLE_API_KEY_PATH:?Set the notarization key path}"
: "${APPLE_API_KEY_ID:?Set the notarization key ID}"
: "${APPLE_API_ISSUER_ID:?Set the notarization issuer ID}"
: "${SPARKLE_PRIVATE_KEY_PATH:?Set the update-signing key path}"
[[ "$NOODLE_SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || { print -u2 'Developer ID required'; exit 1; }

# Only new, product-specific generated output; never erase other release assets.
mkdir -p "$project_root/.release" "$project_root/dist"
staging="$(mktemp -d "$project_root/.release/computer.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output="$project_root/dist/computer-$version"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 1; }
export NOODLE_COMPUTER_CONFIGURATION=release NOODLE_COMPUTER_TEST_BUILD=0
export NOODLE_REQUIRE_DEVELOPER_ID=1 NOODLE_CODESIGN_TIMESTAMP=1
app="$(zsh "$project_root/scripts/build-computer.sh")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.computer ]]
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'
zsh "$project_root/scripts/verify-computer-release.sh" "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/notary.zip"
xcrun notarytool submit "$staging/notary.zip" --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
mkdir "$staging/assets"
archive="Noodle-Computer-$version-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/assets/$archive"
(cd "$staging/assets"; shasum -a 256 "$archive" > "$archive.sha256")
sparkle_tools="$project_root/.build/computer/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
    --download-url-prefix "https://github.com/pdparchitect/noodle/releases/download/$tag/" \
    --full-release-notes-url "https://github.com/pdparchitect/noodle/releases/tag/$tag" \
    --maximum-deltas 0 "$staging/assets"
"$sparkle_tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$staging/assets/appcast.xml"
archive_signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$staging/assets/appcast.xml")"
[[ -n "$archive_signature" ]]
"$sparkle_tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$staging/assets/$archive" "$archive_signature"
mv "$staging/assets" "$output"
print "$output"
