#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Draws the Desktop image's wallpaper from Support/AppSymbol.svg on Images/WallpaperTemplate.svg.
set -euo pipefail
rook_root="${0:A:h:h}"
project_root="${rook_root:h:h}"
module_cache="$project_root/.build/icon-generation/module-cache"
mkdir -p "$module_cache"
swift -module-cache-path "$module_cache" "$rook_root/scripts/generate-wallpaper.swift" \
    "$rook_root/Support/AppSymbol.svg" "$rook_root/Images/WallpaperTemplate.svg" \
    "$rook_root/Images/brand/desktop-wallpaper.png"
