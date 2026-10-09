#!/bin/zsh
# Pure pixel conversion; no guest, window, account, graphics device or timing.
set -euo pipefail
here="${0:A:h}"
repo="${here:h:h:h}"
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
swiftc -DNOODLE_DEV_HOOKS "$repo/Computer/Sources/NoodleComputer/NeptuneScanout.swift" \
    "$here/scanout.swift" -o "$output/scanout-test"
"$output/scanout-test"
