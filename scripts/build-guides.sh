#!/bin/zsh
# Builds an incubating app's Setup Guide and User Guide as PDFs from the pages in its docs folder that name each
# guide, into OUT (dist/guides by default), and prints their paths. The release attaches them to the app's release.
#   scripts/build-guides.sh Pion|Rook [OUT]
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Usage: scripts/build-guides.sh Pion|Rook [OUT]}"
[[ "$app" == Pion || "$app" == Rook ]] || { print -u2 "Only Pion and Rook have guides"; exit 1; }
folder="$project_root/Incubator/$app"
out="${2:-$project_root/dist/guides}"
mkdir -p "$out"
out="${out:A}"
version="$(tr -d '[:space:]' < "$folder/VERSION")"
source="https://github.com/pdparchitect/noodle/blob/main/Incubator/$app/docs"

# Top-level code compiles beside other files only as main.swift.
build="$project_root/.build/guide-pdf"
mkdir -p "$build"
ln -sf "$project_root/scripts/guide-pdf.swift" "$build/main.swift"
"$project_root/scripts/build-priority.sh" xcrun swiftc -O -o "$build/guide-pdf" "$build/main.swift" \
    "$project_root/Shared/Document/Sources/NoodleDocument/MarkdownDocument.swift"

for guide title in setup "Setup Guide" user "User Guide"; do
    pdf="$out/$app-${title// /-}.pdf"
    "$build/guide-pdf" "$folder/docs" "$guide" "$title" "$app" "$version" "$folder/Support/AppIcon.png" "$source" "$pdf"
    print -r -- "$pdf"
done
