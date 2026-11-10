#!/bin/zsh
# Builds, signs and notarizes a public release of Noodle Terminal into dist/terminal-VERSION: the `noodle`
# command in Noodle-Terminal-arm64.zip, with its checksum. A bare command-line binary cannot be stapled, so
# Gatekeeper checks its notarization online the first time it runs.
#   NOODLE_SIGNING_IDENTITY="Developer ID Application: ..." APPLE_API_KEY_PATH=... APPLE_API_KEY_ID=... \
#   APPLE_API_ISSUER_ID=... zsh scripts/package-terminal-release.sh
set -euo pipefail
project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/Terminal/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Invalid Terminal version: $version"; exit 1; }
: "${NOODLE_SIGNING_IDENTITY:?Set the Developer ID signing identity}"
[[ "$NOODLE_SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || { print -u2 'Developer ID required'; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Public Terminal archives require Apple silicon.'; exit 1; }
# Development hooks are never built into a release.
[[ -z "${NOODLE_DEV_HOOKS:-}" ]] || { print -u2 'Unset NOODLE_DEV_HOOKS for a release build.'; exit 1; }

# Only new, product-specific generated output; never erase other release assets.
mkdir -p "$project_root/.release" "$project_root/dist"
staging="$(mktemp -d "$project_root/.release/terminal.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output="$project_root/dist/terminal-$version"
[[ ! -e "$output" ]] || { print -u2 "Release output already exists: $output"; exit 1; }

scratch="$project_root/.build/terminal-release"
zsh "$project_root/scripts/build-priority.sh" swift build -c release --arch arm64 \
    --package-path "$project_root/Terminal" --scratch-path "$scratch" >&2
binary="$(swift build -c release --arch arm64 --package-path "$project_root/Terminal" --scratch-path "$scratch" --show-bin-path)/noodle"
# The archive holds the binary alone; anything the build put beside it would be left behind.
mkdir "$staging/command"
cp "$binary" "$staging/command/noodle"
[[ "$(lipo -archs "$staging/command/noodle")" == arm64 ]] || { print -u2 'The release binary must be arm64 only.'; exit 1; }
codesign --force --options runtime --timestamp --identifier com.pdparchitect.noodle.terminal \
    --sign "$NOODLE_SIGNING_IDENTITY" "$staging/command/noodle"
codesign --verify --strict "$staging/command/noodle"
codesign -dv --verbose=4 "$staging/command/noodle" 2>&1 | grep -q '^Authority=Developer ID Application:'
codesign -dv "$staging/command/noodle" 2>&1 | grep -q 'flags=0x10000(runtime)'
# The signed binary starts on its own, without anything the build left beside it.
usage="$("$staging/command/noodle" --help)"
[[ "$usage" == *'USAGE: noodle'* ]] || { print -u2 'The signed binary did not start.'; exit 1; }

mkdir "$staging/assets"
archive="Noodle-Terminal-arm64.zip"
(cd "$staging/command"; ditto -c -k --sequesterRsrc noodle "$staging/assets/$archive")
zsh "$project_root/scripts/notarize.sh" "$staging/assets/$archive"
(cd "$staging/assets"; shasum -a 256 "$archive" > "$archive.sha256")
mv "$staging/assets" "$output"
print "$output"
