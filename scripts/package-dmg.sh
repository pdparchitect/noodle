#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
preview=0
suite=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --preview) preview=1 ;;
        --suite) suite=1 ;;
        *) print -u2 "Unknown option: $1"; exit 1 ;;
    esac
    shift
done
if (( $# != 2 )); then
    print -u2 'Usage: package-dmg.sh [--preview] [--suite] APP_OR_SUITE_DIRECTORY OUTPUT.dmg'
    exit 1
fi
app="${1:a}"
output="${2:a}"
[[ -d "$app" && "$output" == *.dmg ]] || { print -u2 'Expected application source and OUTPUT.dmg'; exit 1; }
typeset -a bundles builder_options
builder_options=()
if (( suite )); then
    bundles=("$app"/*.app(N))
    (( ${#bundles} >= 3 && ${#bundles} <= 4 )) || { print -u2 'Expected three or four Suite apps'; exit 1; }
    builder_options=(--suite)
else
    [[ "$app" == *.app ]] || { print -u2 'Expected APP'; exit 1; }
    bundles=("$app")
fi
[[ ! -e "$output" && ! -e "$output.sha256" ]] || { print -u2 "Output already exists: $output"; exit 1; }
if (( ! preview )); then
    : "${NOODLE_SIGNING_IDENTITY:?Set a Developer ID Application identity}"
    : "${APPLE_API_KEY_PATH:?Set the notarization key path}"
    : "${APPLE_API_KEY_ID:?Set the notarization key ID}"
    : "${APPLE_API_ISSUER_ID:?Set the notarization issuer ID}"
    [[ "$NOODLE_SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || { print -u2 'Developer ID required'; exit 1; }
    # Release callers pass the same already notarized, stapled app used in ZIPs.
    for bundle in "${bundles[@]}"; do xcrun stapler validate "$bundle"; done
fi

tools_dir="$project_root/.build/dmg-tools"
if [[ ! -x "$tools_dir/bin/python" ]]; then python3 -m venv "$tools_dir"; fi
"$tools_dir/bin/python" -m pip install --disable-pip-version-check --no-cache-dir \
    -r "$project_root/scripts/dmg-requirements.txt" >&2
mkdir -p "${output:h}" "$project_root/.build/dmg-module-cache"
staging="$(mktemp -d "${output:h}/.dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
swift -module-cache-path "$project_root/.build/dmg-module-cache" \
    "$project_root/scripts/dmg-background.swift" "$staging/background.tiff" "${builder_options[@]}"
image="$staging/${output:t}"
"$tools_dir/bin/python" "$project_root/scripts/build-dmg.py" "${builder_options[@]}" "$app" "$staging/background.tiff" "$image" >&2

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
