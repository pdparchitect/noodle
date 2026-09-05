#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
expected_tag="v$version"
release_tag="${1:-${GITHUB_REF_NAME:-}}"
dist="$project_root/dist"
archive_root="$project_root/.release/SuperBot.xcarchive"
export_root="$project_root/.release/export"
notary_input="$project_root/.release/SuperBot-notarization.zip"
archive="$dist/SuperBot-$version-macOS.zip"

if [[ -n "$release_tag" && "$release_tag" != "$expected_tag" ]]; then
    print -u2 "Release tag $release_tag does not match VERSION ($expected_tag)."
    exit 1
fi

: "${APPLE_API_KEY_PATH:?Set APPLE_API_KEY_PATH to an App Store Connect API private key.}"
: "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID.}"
: "${APPLE_API_ISSUER_ID:?Set APPLE_API_ISSUER_ID.}"

rm -rf "$dist" "$project_root/.release"
mkdir -p "$dist" "$project_root/.release"

export SUPERBOT_BUILD_CONFIGURATION=release
export SUPERBOT_BUILD_NUMBER="${SUPERBOT_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "$project_root" rev-list --count HEAD)}}"
export SUPERBOT_SIGNING_IDENTITY="-"
unsigned_app="$("$project_root/scripts/build-app.sh")"

mkdir -p "$archive_root/Products/Applications" "$export_root"
ditto "$unsigned_app" "$archive_root/Products/Applications/SuperBot.app"
cp "$project_root/Support/ArchiveInfo.plist" "$archive_root/Info.plist"
/usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleShortVersionString $version" "$archive_root/Info.plist"
/usr/libexec/PlistBuddy -c "Set :ApplicationProperties:CFBundleVersion $SUPERBOT_BUILD_NUMBER" "$archive_root/Info.plist"
plutil -replace CreationDate -date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$archive_root/Info.plist"

xcodebuild -exportArchive \
    -archivePath "$archive_root" \
    -exportPath "$export_root" \
    -exportOptionsPlist "$project_root/Support/ExportOptions.plist" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$APPLE_API_KEY_PATH" \
    -authenticationKeyID "$APPLE_API_KEY_ID" \
    -authenticationKeyIssuerID "$APPLE_API_ISSUER_ID"

app="$export_root/SuperBot.app"
if ! codesign -dv --verbose=4 "$app" 2>&1 | grep -q '^Authority=Developer ID Application:'; then
    print -u2 "Xcode did not export SuperBot with a Developer ID Application signature."
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app"
app_entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null | tr -d '[:space:]')"
entitlement_count="$(print -r -- "$app_entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
if [[ "$entitlement_count" != "4" ]] \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.files.user-selected.read-only</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.network.client</key><true/>' \
    || ! print -r -- "$app_entitlements" | grep -q '<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key><array><string>/.codex/</string></array>'; then
    print -u2 "The exported app's sandbox entitlements do not match the reviewed four-key policy."
    exit 1
fi

helper_entitlements="$(codesign -d --entitlements :- "$app/Contents/Helpers/messenger" 2>/dev/null)"
if print -r -- "$helper_entitlements" | grep -q '<key>'; then
    print -u2 "The exported Messenger helper unexpectedly has application entitlements."
    exit 1
fi

if otool -L "$app/Contents/MacOS/SuperBot" "$app/Contents/Helpers/messenger" | grep -Eq '/opt/homebrew|/usr/local'; then
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

print "$archive"
