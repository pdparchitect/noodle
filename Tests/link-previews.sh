#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
mkdir -p "$project_root/.build"
xcrun swiftc -parse-as-library \
    "$project_root/Sources/Noodle/MessageLinkPreview.swift" \
    "$project_root/Tests/link-previews.swift" \
    -o "$project_root/.build/LinkPreviewChecks"
"$project_root/.build/LinkPreviewChecks"
