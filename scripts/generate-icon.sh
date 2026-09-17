#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
if (( $# != 0 && $# != 2 )); then
    print -u2 'Usage: generate-icon.sh [AppSymbol.svg OUTPUT.iconset]'
    exit 1
fi
source_svg="${1:-$project_root/Support/AppSymbol.svg}"
iconset="${2:-$project_root/Support/Assets.xcassets/AppIcon.appiconset}"
module_cache="$project_root/.build/icon-generation/module-cache"
mkdir -p "$module_cache"

swift -module-cache-path "$module_cache" "$project_root/scripts/generate-icon.swift" \
    "$source_svg" "$project_root/Support/AppIconTemplate.svg" "$iconset"
