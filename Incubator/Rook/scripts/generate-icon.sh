#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Draws Rook's icon from Support/AppSymbol.svg on its own tile in Support/AppIconTemplate.svg,
# with the repository's icon renderer.
set -euo pipefail
rook_root="${0:A:h:h}"
project_root="${rook_root:h:h}"
module_cache="$project_root/.build/icon-generation/module-cache"
mkdir -p "$module_cache"
swift -module-cache-path "$module_cache" "$project_root/scripts/generate-icon.swift" \
    "$rook_root/Support/AppSymbol.svg" "$rook_root/Support/AppIconTemplate.svg" \
    "$rook_root/Support/Assets.xcassets/RookIcon.appiconset" macos
