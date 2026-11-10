#!/bin/zsh
# Publishes Noodle Terminal's prepared release from dist/terminal-VERSION: the immutable terminal-vVERSION
# release, then the terminal-latest channel whose fixed-name download the README links to.
set -euo pipefail
project_root="${0:A:h:h}"
version="${1:?Usage: scripts/publish-terminal-release.sh VERSION NOTES}"
notes="${2:?Pass the release notes file}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
[[ "$version" == "$(tr -d '[:space:]' < "$project_root/Terminal/VERSION")" ]] || exit 1
tag="terminal-v$version"
channel="terminal-latest"
repo="pdparchitect/noodle"
assets="$project_root/dist/terminal-$version"
archive="Noodle-Terminal-arm64.zip"
[[ -s "$notes" && -s "$assets/$archive" && -s "$assets/$archive.sha256" ]]
(cd "$assets"; shasum -a 256 -c "$archive.sha256")
[[ "$(gh api "repos/$repo" --jq .private)" == false ]]
# Refuse to replace immutable published assets, or regress the stable channel.
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    print -u2 "Release $tag already exists. Do not overwrite published archives; inspect and repair a failed promotion separately."; exit 1
fi
channel_title="$(gh release view "$channel" --repo "$repo" --json name --jq .name 2>/dev/null || true)"
if [[ -n "$channel_title" ]]; then
    previous="${channel_title#Noodle Terminal }"
    [[ "$previous" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Unrecognized Terminal channel version'; exit 1; }
    autoload -Uz is-at-least
    is-at-least "$previous" "$version" || { print -u2 'Refusing to roll back the Terminal channel'; exit 1; }
fi
gh release create "$tag" "$assets/$archive" "$assets/$archive.sha256" \
    --repo "$repo" --verify-tag --draft --latest=false --title "Noodle Terminal $version" --notes-file "$notes"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# The channel is a marker, not a version tag, and never becomes the repository's latest release.
page="Noodle Terminal $version. [Download ZIP for Apple silicon](https://github.com/$repo/releases/download/$channel/$archive) · [Release notes](https://github.com/$repo/releases/tag/$tag)"
if [[ -z "$channel_title" ]]; then
    gh release create "$channel" "$assets/$archive" "$assets/$archive.sha256" \
        --repo "$repo" --target "$(git -C "$project_root" rev-parse "$tag^{commit}")" \
        --draft --latest=false --title "Noodle Terminal $version" --notes "$page"
    gh release edit "$channel" --repo "$repo" --draft=false --latest=false
else
    gh release upload "$channel" "$assets/$archive" "$assets/$archive.sha256" --repo "$repo" --clobber
    gh release edit "$channel" --repo "$repo" --latest=false --title "Noodle Terminal $version" --notes "$page"
fi
