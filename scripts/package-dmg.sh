#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
preview=0
if [[ "${1:-}" == --preview ]]; then preview=1; shift; fi
if (( $# != 2 )); then
    print -u2 'Usage: package-dmg.sh [--preview] APP OUTPUT.dmg'
    exit 1
fi
app="${1:a}"
output="${2:a}"
[[ -d "$app" && "$app" == *.app && "$output" == *.dmg ]] || { print -u2 'Expected APP and OUTPUT.dmg'; exit 1; }
[[ ! -e "$output" && ! -e "$output.sha256" ]] || { print -u2 "Output already exists: $output"; exit 1; }
if (( ! preview )); then
    : "${NOODLE_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
    : "${APPLE_API_KEY_PATH:?Set the notarization key path}"
    : "${APPLE_API_KEY_ID:?Set the notarization key ID}"
    : "${APPLE_API_ISSUER_ID:?Set the notarization issuer ID}"
    [[ "$NOODLE_SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || { print -u2 'Developer ID required'; exit 1; }
    # Release callers pass the same already notarized, stapled app used in ZIPs.
    xcrun stapler validate "$app"
fi

tools_dir="$project_root/.build/dmg-tools"
if [[ ! -x "$tools_dir/bin/python" ]]; then python3 -m venv "$tools_dir"; fi
"$tools_dir/bin/python" -m pip install --disable-pip-version-check --no-cache-dir \
    -r "$project_root/scripts/dmg-requirements.txt" >&2
mkdir -p "${output:h}" "$project_root/.build/dmg-module-cache"
staging="$(mktemp -d "${output:h}/.dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
swift -module-cache-path "$project_root/.build/dmg-module-cache" \
    "$project_root/scripts/dmg-background.swift" "$staging/background.tiff"
image="$staging/${output:t}"
"$tools_dir/bin/python" "$project_root/scripts/build-dmg.py" "$app" "$staging/background.tiff" "$image" >&2

if (( ! preview )); then
    codesign --force --timestamp --sign "$NOODLE_SIGNING_IDENTITY" "$image"
    codesign --verify --strict "$image"
    xcrun notarytool submit "$image" --key "$APPLE_API_KEY_PATH" \
        --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" --wait
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
fi
# Checksums cover the final stapled bytes. Move only fully verified output.
(cd "$staging"; shasum -a 256 "${output:t}" > "${output:t}.sha256")
mv "$image" "$output"
mv "$image.sha256" "$output.sha256"
print "$output"
