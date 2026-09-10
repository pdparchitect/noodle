#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
version="${1:?Pass the Computer version}"
notes="${2:?Pass the release notes file}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
[[ "$version" == "$(tr -d '[:space:]' < "$project_root/Computer/VERSION")" ]] || exit 1
tag="computer-v$version"
repo="pdparchitect/noodle"
channel=computer-latest
assets="$project_root/dist/computer-$version"
archive="Noodle-Computer-$version-arm64.zip"
[[ -s "$notes" && -s "$assets/$archive" && -s "$assets/$archive.sha256" && -s "$assets/appcast.xml" ]]
[[ "$(gh api "repos/$repo" --jq .private)" == false ]]
# Refuse to replace immutable published assets, or regress the stable channel.
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    print -u2 "Release $tag already exists. Do not overwrite published archives; inspect and repair a failed promotion separately."; exit 1
fi
channel_title="$(gh release view "$channel" --repo "$repo" --json name --jq .name 2>/dev/null || true)"
if [[ -n "$channel_title" ]]; then
    previous="${channel_title#Noodle Computer }"
    [[ "$previous" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Unrecognized Computer channel version'; exit 1; }
    autoload -Uz is-at-least
    is-at-least "$previous" "$version" || { print -u2 'Refusing to roll back the Computer update channel'; exit 1; }
fi
gh release create "$tag" "$assets/$archive" "$assets/$archive.sha256" "$assets/appcast.xml" \
    --repo "$repo" --verify-tag --draft --latest=false --title "Noodle Computer $version" --notes-file "$notes"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# The stable landing page and signed feed only point at the immutable release.
# This tag is a channel marker, not a version tag. It never becomes repo latest.
channel_notes="Noodle Computer $version

[Download for Apple silicon](https://github.com/$repo/releases/download/$tag/$archive)

Requires macOS 26 or later. Unzip and move Noodle Computer.app to Applications, then return to Noodle and add a computer. Both apps must be signed by the same publisher.

[Release notes and checksum](https://github.com/$repo/releases/tag/$tag)

Updating or quitting Computer stops its running computers. Save guest work first.
"
if [[ -z "$channel_title" ]]; then
    gh release create "$channel" "$assets/appcast.xml" --repo "$repo" --target "$(git -C "$project_root" rev-parse "$tag^{commit}")" \
        --draft --latest=false --title "Noodle Computer $version" --notes "$channel_notes"
    gh release edit "$channel" --repo "$repo" --draft=false --latest=false
else
    gh release upload "$channel" "$assets/appcast.xml" --repo "$repo" --clobber
    gh release edit "$channel" --repo "$repo" --latest=false --title "Noodle Computer $version" --notes "$channel_notes"
fi
