#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
version="$(tr -d '[:space:]' < "$project_root/Computer/VERSION")"
tag="computer-v$version"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid Computer/VERSION'; exit 1; }
grep -Eq "^## \\[$version\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" "$project_root/Computer/CHANGELOG.md" || {
    print -u2 'Prepare approved, dated Computer release notes before tagging.'; exit 1
}
[[ -z "$(git -C "$project_root" status --porcelain)" ]] || { print -u2 'Commit changes before tagging.'; exit 1; }
if git -C "$project_root" rev-parse --verify "refs/tags/$tag" >/dev/null 2>&1; then
    print -u2 "Tag $tag already exists."; exit 1
fi
git -C "$project_root" tag -a "$tag" -m "Noodle Computer $version"
git -C "$project_root" push origin "$tag"
