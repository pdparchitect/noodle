#!/bin/zsh
# Builds, signs, notarizes and packages a public release of an app built from its Project.swift.
# Everything else follows from the app's name: APP/VERSION and APP/CHANGELOG.md, the app-v tag,
# com.pdparchitect.noodle.app, Noodle-APP-arm64.zip and scripts/verify-app-release.sh. Noodle is the
# repository itself: VERSION, CHANGELOG.md, the v tag, com.pdparchitect.noodle and Noodle-arm64.zip.
# An app with Support/update-milestones.json has them applied to its update feed.
set -euo pipefail
project_root="${0:A:h:h}"
app_folder="${1:?Usage: scripts/package-xcode-release.sh APP TAG}"
product="${(L)app_folder}"
setting="${(U)app_folder}"
if [[ "$app_folder" == Noodle ]]; then
    folder="$project_root"; app_name=Noodle; bundle=com.pdparchitect.noodle; tag_prefix=v
else
    folder="$project_root/$app_folder"; app_name="Noodle $app_folder"; bundle="com.pdparchitect.noodle.$product"; tag_prefix="$product-v"
fi
[[ -f "$folder/Project.swift" ]] || { print -u2 "$app_folder has no Project.swift."; exit 1; }
version="$(tr -d '[:space:]' < "$folder/VERSION")"
tag="$tag_prefix$version"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Invalid $app_folder VERSION"; exit 1; }
[[ "${2:-}" == "$tag" ]] || { print -u2 "Expected release tag $tag"; exit 1; }
grep -Eq "^## \\[$version\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$folder/CHANGELOG.md" || {
    print -u2 "$app_folder release notes are not approved and dated."; exit 1
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
staging="$(mktemp -d "$project_root/.release/$product.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output="$project_root/dist/$product-$version"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 "Public $app_folder archives require Apple silicon."; exit 1; }

# Release is the production identity. A public release signs with Developer ID, timestamps every
# signature and turns updates on, through the project's <APP>_CODESIGN_TIMESTAMP and
# <APP>_UPDATES_ENABLED settings.
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$folder" && "$tuist" generate --no-open >&2)
derived="$project_root/.build/$product-release"
scheme="${app_name// /}"
xcodebuild -workspace "$folder/$scheme.xcworkspace" -scheme "$scheme" \
    -configuration Release -derivedDataPath "$derived" -destination 'generic/platform=macOS' \
    -archivePath "$staging/$scheme.xcarchive" -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$NOODLE_SIGNING_IDENTITY" DEVELOPMENT_TEAM="$team" \
    OTHER_CODE_SIGN_FLAGS=--timestamp "${setting}_CODESIGN_TIMESTAMP=--timestamp" \
    "INFOPLIST_PREPROCESSOR_DEFINITIONS=${setting}_UPDATES_ENABLED=true" archive >&2
app="$staging/$app_name.app"
ditto "$staging/$scheme.xcarchive/Products/Applications/$app_name.app" "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$bundle" ]]
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'
NOODLE_REQUIRE_DEVELOPER_ID=1 zsh "$project_root/scripts/verify-$product-release.sh" "$app"
zsh "$project_root/scripts/verify-launch-hooks.sh" "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/notary.zip"
xcrun notarytool submit "$staging/notary.zip" --key "$APPLE_API_KEY_PATH" \
    --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
mkdir "$staging/assets"
archive="${app_name// /-}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/assets/$archive"
(cd "$staging/assets"; shasum -a 256 "$archive" > "$archive.sha256")
sparkle_tools="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
"$sparkle_tools/generate_appcast" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
    --download-url-prefix "https://github.com/pdparchitect/noodle/releases/download/$tag/" \
    --full-release-notes-url "https://github.com/pdparchitect/noodle/releases/tag/$tag" \
    --maximum-deltas 0 "$staging/assets"
if [[ -f "$folder/Support/update-milestones.json" ]]; then
    python3 "$project_root/scripts/prepare-update-feed.py" --version "$version" --feed "$staging/assets/appcast.xml" \
        --milestones "$folder/Support/update-milestones.json" --sign-update "$sparkle_tools/sign_update" \
        --key-file "$SPARKLE_PRIVATE_KEY_PATH" --tag-prefix "$tag_prefix" --archive "$archive"
fi
"$sparkle_tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$staging/assets/appcast.xml"
archive_signature="$(xmllint --xpath 'string(//enclosure/@*[local-name()="edSignature"])' "$staging/assets/appcast.xml")"
[[ -n "$archive_signature" ]]
"$sparkle_tools/sign_update" --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" --verify "$staging/assets/$archive" "$archive_signature"
# Build after generate_appcast so Sparkle continues to use only the ZIP.
zsh "$project_root/scripts/package-dmg.sh" "$app" "$staging/assets/${archive:r}.dmg"
# Release workflows run their smoke tests on the stapled app in .build.
rm -rf "$project_root/.build/$app_name.app"
ditto "$app" "$project_root/.build/$app_name.app"
mv "$staging/assets" "$output"
print "$output"
