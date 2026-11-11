#!/bin/bash
# Builds Noodle Server for this machine's processor and packs it with its service and example
# configuration, as dist/server-VERSION/Noodle-Server-linux-ARCH.tar.gz and its checksum.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(tr -d '[:space:]' < "$root/Server/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid Server/VERSION: $version" >&2; exit 1; }
case "$(uname -m)" in
    aarch64 | arm64) arch=arm64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "Noodle Server is built for arm64 and x86_64 only." >&2; exit 1 ;;
esac

# The Swift runtime goes inside the program, so a server needs no Swift installed.
build=(swift build -c release --package-path "$root/Server" --scratch-path "$root/.build/server-release"
       --product noodled --static-swift-stdlib)
"${build[@]}"
binary="$("${build[@]}" --show-bin-path)/noodled"
"$binary" help > /dev/null

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/noodled"
install -m 755 "$binary" "$stage/noodled/noodled"
strip "$stage/noodled/noodled"
install -m 644 "$root/Server/noodled.yaml" "$root/Server/noodled.service" "$root/Server/README.md" "$stage/noodled/"

out="$root/dist/server-$version"
archive="Noodle-Server-linux-$arch.tar.gz"
mkdir -p "$out"
tar -C "$stage" --owner=0 --group=0 --numeric-owner -czf "$out/$archive" noodled
(cd "$out" && sha256sum "$archive" > "$archive.sha256")
echo "Packed $out/$archive"
