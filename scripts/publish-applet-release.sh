#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
version="${1:?Pass the Applet version}"
notes="${2:?Pass the release notes file}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
[[ "$version" == "$(tr -d '[:space:]' < "$project_root/Applet/VERSION")" ]] || exit 1
tag="applet-v$version"
repo="pdparchitect/noodle"
channel=applet-latest
assets="$project_root/dist/applet-$version"
archive="Noodle-Applet-$version-arm64.zip"
[[ -s "$notes" && -s "$assets/$archive" && -s "$assets/$archive.sha256" && -s "$assets/appcast.xml" ]]
[[ "$(gh api "repos/$repo" --jq .private)" == false ]]
# Refuse to replace immutable published assets, or regress the stable channel.
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    print -u2 "Release $tag already exists. Do not overwrite published archives; inspect and repair a failed promotion separately."; exit 1
fi
channel_title="$(gh release view "$channel" --repo "$repo" --json name --jq .name 2>/dev/null || true)"
if [[ -n "$channel_title" ]]; then
    previous="${channel_title#Noodle Applet }"
    [[ "$previous" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Unrecognized Applet channel version'; exit 1; }
    autoload -Uz is-at-least
    is-at-least "$previous" "$version" || { print -u2 'Refusing to roll back the Applet update channel'; exit 1; }
fi
gh release create "$tag" "$assets/$archive" "$assets/$archive.sha256" "$assets/appcast.xml" \
    --repo "$repo" --verify-tag --draft --latest=false --title "Noodle Applet $version" --notes-file "$notes"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# The stable landing page includes copies of the current download assets.
# The signed feed still points at the immutable versioned release.
# This tag is a channel marker, not a version tag. It never becomes repo latest.
channel_notes="Noodle Applet $version

[Download for Apple silicon](https://github.com/$repo/releases/download/$tag/$archive)

Requires macOS 15 or later. Unzip and move Noodle Applet.app to Applications. Swift noodlets also require Apple developer tools. Noodle and Applet must be signed by the same publisher.

[Release notes and checksum](https://github.com/$repo/releases/tag/$tag)

Updating or quitting Applet stops its running noodlets. Save your work first.
"
if [[ -z "$channel_title" ]]; then
    gh release create "$channel" "$assets/$archive" "$assets/$archive.sha256" "$assets/appcast.xml" \
        --repo "$repo" --target "$(git -C "$project_root" rev-parse "$tag^{commit}")" \
        --draft --latest=false --title "Noodle Applet $version" --notes "$channel_notes"
    gh release edit "$channel" --repo "$repo" --draft=false --latest=false
else
    # Keep the previous downloads/feed available until both new downloads exist.
    gh release upload "$channel" "$assets/$archive" "$assets/$archive.sha256" --repo "$repo"
    gh release upload "$channel" "$assets/appcast.xml" --repo "$repo" --clobber
    gh release edit "$channel" --repo "$repo" --latest=false --title "Noodle Applet $version" --notes "$channel_notes"
    # Only remove the preceding version's channel copies; immutable releases and
    # unrelated attachments are retained. Older channels may have no ZIP assets.
    previous_archive="Noodle-Applet-$previous-arm64.zip"
    if [[ "$previous_archive" != "$archive" ]]; then
        channel_assets="$(gh release view "$channel" --repo "$repo" --json assets --jq '.assets[].name')"
        for asset in "${(@f)channel_assets}"; do
            if [[ "$asset" == "$previous_archive" || "$asset" == "$previous_archive.sha256" ]]; then
                gh release delete-asset "$channel" "$asset" --repo "$repo" --yes
            fi
        done
    fi
fi
