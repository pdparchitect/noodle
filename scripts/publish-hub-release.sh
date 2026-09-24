#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
version="${1:?Pass the Hub version}"
notes="${2:?Pass the release notes file}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
[[ "$version" == "$(tr -d '[:space:]' < "$project_root/Hub/VERSION")" ]] || exit 1
tag="hub-v$version"
repo="pdparchitect/noodle"
channel=hub-latest
assets="$project_root/dist/hub-$version"
archive="Noodle-Hub-arm64.zip"
disk_image="${archive:r}.dmg"
[[ -s "$assets/$disk_image" && -s "$assets/$disk_image.sha256" ]]
(cd "$assets"; shasum -a 256 -c "$archive.sha256" "$disk_image.sha256")
[[ -s "$notes" && -s "$assets/$archive" && -s "$assets/$archive.sha256" && -s "$assets/appcast.xml" ]]
[[ "$(gh api "repos/$repo" --jq .private)" == false ]]
# Refuse to replace immutable published assets, or regress the stable channel.
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    print -u2 "Release $tag already exists. Do not overwrite published archives; inspect and repair a failed promotion separately."; exit 1
fi
channel_title="$(gh release view "$channel" --repo "$repo" --json name --jq .name 2>/dev/null || true)"
if [[ -n "$channel_title" ]]; then
    previous="${channel_title#Noodle Hub }"
    [[ "$previous" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Unrecognized Hub channel version'; exit 1; }
    autoload -Uz is-at-least
    is-at-least "$previous" "$version" || { print -u2 'Refusing to roll back the Hub update channel'; exit 1; }
fi
gh release create "$tag" "$assets/$archive" "$assets/$archive.sha256" "$assets/$disk_image" "$assets/$disk_image.sha256" "$assets/appcast.xml" \
    --repo "$repo" --verify-tag --draft --latest=false --title "Noodle Hub $version" --notes-file "$notes"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# The stable landing page includes copies of the current download assets.
# The signed feed still points at the immutable versioned release.
# This tag is a channel marker, not a version tag. It never becomes repo latest.
channel_notes="Noodle Hub $version

Early development build: Noodle Hub does not run bots yet.

[Download DMG for Apple silicon](https://github.com/$repo/releases/download/$tag/$disk_image) · [ZIP](https://github.com/$repo/releases/download/$tag/$archive)

Requires macOS 26 or later. Open the DMG and drag Noodle Hub.app to Applications on the Mac that runs your bots.

[Release notes and checksum](https://github.com/$repo/releases/tag/$tag)
"
if [[ -z "$channel_title" ]]; then
    gh release create "$channel" "$assets/$archive" "$assets/$archive.sha256" "$assets/$disk_image" "$assets/$disk_image.sha256" "$assets/appcast.xml" \
        --repo "$repo" --target "$(git -C "$project_root" rev-parse "$tag^{commit}")" \
        --draft --latest=false --title "Noodle Hub $version" --notes "$channel_notes"
    gh release edit "$channel" --repo "$repo" --draft=false --latest=false
else
    # Replace fixed-name downloads only on the mutable channel. Publish its feed
    # after the downloads and checksums upload successfully; immutable versioned releases are never replaced.
    gh release upload "$channel" "$assets/$archive" "$assets/$archive.sha256" "$assets/$disk_image" "$assets/$disk_image.sha256" --repo "$repo" --clobber
    gh release upload "$channel" "$assets/appcast.xml" --repo "$repo" --clobber
    gh release edit "$channel" --repo "$repo" --latest=false --title "Noodle Hub $version" --notes "$channel_notes"
fi
