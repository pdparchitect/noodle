#!/bin/zsh
# Installs the pinned Tuist under ~/.local/tuist when missing and prints its path. The download must
# match the published SHA-256, so a changed or tampered release is refused.
set -euo pipefail
version=4.209.0
sha256=d390e058348729acfc79e30bcc467aef2aabe3881edbd2c8d43fa7f4d62ea1d7
install="$HOME/.local/tuist/$version"
if [[ ! -x "$install/tuist" ]]; then
    download="$(mktemp -d)"
    trap 'rm -rf "$download"' EXIT
    curl -fsSL "https://github.com/tuist/tuist/releases/download/$version/tuist.zip" -o "$download/tuist.zip"
    [[ "$(shasum -a 256 "$download/tuist.zip" | cut -d' ' -f1)" == "$sha256" ]] || {
        print -u2 "Tuist $version does not match its published checksum."; exit 1
    }
    mkdir -p "$install"
    ditto -x -k "$download/tuist.zip" "$install"
fi
print "$install/tuist"
