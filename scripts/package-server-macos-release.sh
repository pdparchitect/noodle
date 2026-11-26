#!/bin/zsh
# Builds, signs and notarizes Noodle Server for the Mac into dist/server-VERSION: `noodled`, with the example
# configuration and README, in Noodle-Server-macos-arm64.zip, with its checksum. A bare command-line binary cannot
# be stapled, so Gatekeeper checks its notarization online the first time it runs.
#   NOODLE_SIGNING_IDENTITY="Developer ID Application: ..." APPLE_API_KEY_PATH=... APPLE_API_KEY_ID=... \
#   APPLE_API_ISSUER_ID=... zsh scripts/package-server-macos-release.sh
set -euo pipefail
project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/Server/VERSION")"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Invalid Server version: $version"; exit 1; }
: "${NOODLE_SIGNING_IDENTITY:?Set the Developer ID signing identity}"
[[ "$NOODLE_SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || { print -u2 'Developer ID required'; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { print -u2 'Public Server archives for the Mac require Apple silicon.'; exit 1; }

# Only new, product-specific generated output; never erase other release assets, such as the Linux archives.
mkdir -p "$project_root/.release" "$project_root/dist"
staging="$(mktemp -d "$project_root/.release/server.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
output="$project_root/dist/server-$version"
archive="Noodle-Server-macos-arm64.zip"
[[ ! -e "$output/$archive" ]] || { print -u2 "Release output already exists: $output/$archive"; exit 1; }

build=(swift build -c release --arch arm64 --package-path "$project_root/Server"
       --scratch-path "$project_root/.build/server-release" --product noodled)
zsh "$project_root/scripts/build-priority.sh" "${build[@]}" >&2
binary="$("${build[@]}" --show-bin-path)/noodled"
# The archive holds the program, the example configuration and the README; anything else the build put beside the
# program would be left behind.
mkdir "$staging/noodled"
cp "$binary" "$staging/noodled/noodled"
[[ "$(lipo -archs "$staging/noodled/noodled")" == arm64 ]] || { print -u2 'The release binary must be arm64 only.'; exit 1; }
codesign --force --options runtime --timestamp --identifier com.pdparchitect.noodle.server \
    --sign "$NOODLE_SIGNING_IDENTITY" "$staging/noodled/noodled"
codesign --verify --strict "$staging/noodled/noodled"
codesign -dv --verbose=4 "$staging/noodled/noodled" 2>&1 | grep -q '^Authority=Developer ID Application:'
codesign -dv "$staging/noodled/noodled" 2>&1 | grep -q 'flags=0x10000(runtime)'
# The signed binary starts on its own, without anything the build left beside it.
usage="$("$staging/noodled/noodled" help)"
[[ "$usage" == *'USAGE: noodled'* ]] || { print -u2 'The signed binary did not start.'; exit 1; }
cp "$project_root/Server/noodled.yaml" "$project_root/Server/README.md" "$staging/noodled/"

mkdir "$staging/assets"
(cd "$staging"; ditto -c -k --sequesterRsrc --keepParent noodled "$staging/assets/$archive")
zsh "$project_root/scripts/notarize.sh" "$staging/assets/$archive"
(cd "$staging/assets"; shasum -a 256 "$archive" > "$archive.sha256")
mkdir -p "$output"
mv "$staging/assets/$archive" "$staging/assets/$archive.sha256" "$output/"
print "$output/$archive"
