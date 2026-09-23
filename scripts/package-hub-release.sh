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
team="${${NOODLE_SIGNING_IDENTITY##*\(}%\)}"
[[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 'The signing identity names no team.'; exit 1; }

# Only new, product-specific generated output; never erase other release assets.
mkdir -p "$project_root/.release" "$project_root/dist"
staging="$(mktemp -d "$project_root/.release/hub.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output="$project_root/dist/hub-$version"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Public Hub archives require Apple silicon.'; exit 1; }

# Archive the Xcode project Tuist generates from Hub/Project.swift. Release is the production identity;
# a public release signs with Developer ID, timestamps every signature and turns updates on.
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$project_root/Hub" && "$tuist" generate --no-open >&2)
derived="$project_root/.build/hub-release"
xcodebuild -workspace "$project_root/Hub/NoodleHub.xcworkspace" -scheme NoodleHub -configuration Release \
    -derivedDataPath "$derived" -destination 'generic/platform=macOS' -archivePath "$staging/NoodleHub.xcarchive" \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$NOODLE_SIGNING_IDENTITY" DEVELOPMENT_TEAM="$team" \
    OTHER_CODE_SIGN_FLAGS=--timestamp HUB_CODESIGN_TIMESTAMP=--timestamp \
    INFOPLIST_PREPROCESSOR_DEFINITIONS=HUB_UPDATES_ENABLED=true archive >&2
app="$staging/Noodle Hub.app"
ditto "$staging/NoodleHub.xcarchive/Products/Applications/Noodle Hub.app" "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.hub ]]
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'
NOODLE_REQUIRE_DEVELOPER_ID=1 zsh "$project_root/scripts/verify-hub-release.sh" "$app"
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
sparkle_tools="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
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
