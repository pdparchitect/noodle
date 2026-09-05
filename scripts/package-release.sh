#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
expected_tag="v$version"
release_tag="${1:-${GITHUB_REF_NAME:-}}"
dist="$project_root/dist"
notary_input="$project_root/.release/SuperBot-notarization.zip"
archive="$dist/SuperBot-$version-macOS.zip"

if [[ -n "$release_tag" && "$release_tag" != "$expected_tag" ]]; then
    print -u2 "Release tag $release_tag does not match VERSION ($expected_tag)."
    exit 1
fi

: "${SUPERBOT_SIGNING_IDENTITY:?Set SUPERBOT_SIGNING_IDENTITY to a Developer ID Application identity.}"
: "${APPLE_API_KEY_PATH:?Set APPLE_API_KEY_PATH to an App Store Connect API private key.}"
: "${APPLE_API_KEY_ID:?Set APPLE_API_KEY_ID.}"
: "${APPLE_API_ISSUER_ID:?Set APPLE_API_ISSUER_ID.}"

if [[ "$SUPERBOT_SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    print -u2 "SUPERBOT_SIGNING_IDENTITY must be a Developer ID Application identity."
    exit 1
fi

rm -rf "$dist" "$project_root/.release"
mkdir -p "$dist" "$project_root/.release"

export SUPERBOT_BUILD_CONFIGURATION=release
export SUPERBOT_BUILD_NUMBER="${SUPERBOT_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "$project_root" rev-list --count HEAD)}}"
export SUPERBOT_CODESIGN_TIMESTAMP=1
export SUPERBOT_REQUIRE_DEVELOPER_ID=1
app="$("$project_root/scripts/build-app.sh")"

codesign --verify --deep --strict --verbose=2 "$app"
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
