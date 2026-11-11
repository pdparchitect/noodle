#!/bin/bash
# Builds Noodle Terminal for Linux on this machine's processor, as dist/terminal-VERSION/
# Noodle-Terminal-linux-ARCH.tar.gz holding the `noodle` command, with its checksum.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '[:space:]' < "$root/Terminal/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid Terminal/VERSION: $version" >&2; exit 1; }
case "$(uname -m)" in
    aarch64 | arm64) arch=arm64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "Noodle Terminal is built for arm64 and x86_64 only." >&2; exit 1 ;;
esac
# Development hooks are never built into a release.
[[ -z "${NOODLE_DEV_HOOKS:-}" ]] || { echo 'Unset NOODLE_DEV_HOOKS for a release build.' >&2; exit 1; }

# The Swift runtime goes inside the command, so a computer needs no Swift installed.
build=(swift build -c release --package-path "$root/Terminal" --scratch-path "$root/.build/terminal-linux-release"
       --product noodle --static-swift-stdlib)
"${build[@]}"
binary="$("${build[@]}" --show-bin-path)/noodle"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
install -m 755 "$binary" "$stage/noodle"
strip "$stage/noodle"
usage="$("$stage/noodle" --help)"
[[ "$usage" == *'USAGE: noodle'* ]] || { echo 'The release binary did not start.' >&2; exit 1; }

out="$root/dist/terminal-$version"
archive="Noodle-Terminal-linux-$arch.tar.gz"
mkdir -p "$out"
tar -C "$stage" --owner=0 --group=0 --numeric-owner -czf "$out/$archive" noodle
(cd "$out" && sha256sum "$archive" > "$archive.sha256")
echo "Packed $out/$archive"
