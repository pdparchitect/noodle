#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/VERSION")"
tag="v$version"

if [[ -n "$(git -C "$project_root" status --porcelain)" ]]; then
    print -u2 "Commit all changes before creating a release tag."
    exit 1
fi

if git -C "$project_root" rev-parse "$tag" >/dev/null 2>&1; then
    print -u2 "Tag $tag already exists."
    exit 1
fi

git -C "$project_root" tag -a "$tag" -m "Noodle $version"
git -C "$project_root" push origin main
git -C "$project_root" push origin "$tag"
