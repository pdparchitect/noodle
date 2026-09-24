#!/bin/zsh
# Publishes a companion's prepared release, from dist/<app>-VERSION: the immutable <app>-vVERSION
# release, then its <app>-latest download channel, whose page is APP/Support/download-page.md with
# {version}, {dmg}, {zip} and {release} filled in. Noodle publishes as the repository's latest release
# instead, in the release workflow.
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Usage: scripts/publish-xcode-release.sh APP VERSION NOTES}"
version="${2:?Pass the $app version}"
notes="${3:?Pass the release notes file}"
product="${(L)app}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
[[ "$version" == "$(tr -d '[:space:]' < "$project_root/$app/VERSION")" ]] || exit 1
tag="$product-v$version"
repo="pdparchitect/noodle"
channel="$product-latest"
assets="$project_root/dist/$product-$version"
archive="Noodle-$app-arm64.zip"
disk_image="${archive:r}.dmg"
page="$(<"$project_root/$app/Support/download-page.md")"
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
    previous="${channel_title#Noodle $app }"
    [[ "$previous" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Unrecognized $app channel version"; exit 1; }
    autoload -Uz is-at-least
    is-at-least "$previous" "$version" || { print -u2 "Refusing to roll back the $app update channel"; exit 1; }
fi
gh release create "$tag" "$assets/$archive" "$assets/$archive.sha256" "$assets/$disk_image" "$assets/$disk_image.sha256" "$assets/appcast.xml" \
    --repo "$repo" --verify-tag --draft --latest=false --title "Noodle $app $version" --notes-file "$notes"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# The stable landing page includes copies of the current download assets.
# The signed feed still points at the immutable versioned release.
# This tag is a channel marker, not a version tag. It never becomes repo latest.
downloads="https://github.com/$repo/releases/download/$tag"
page="${page//\{version\}/$version}"
page="${page//\{dmg\}/$downloads/$disk_image}"
page="${page//\{zip\}/$downloads/$archive}"
page="${page//\{release\}/https://github.com/$repo/releases/tag/$tag}"
if [[ -z "$channel_title" ]]; then
    gh release create "$channel" "$assets/$archive" "$assets/$archive.sha256" "$assets/$disk_image" "$assets/$disk_image.sha256" "$assets/appcast.xml" \
        --repo "$repo" --target "$(git -C "$project_root" rev-parse "$tag^{commit}")" \
        --draft --latest=false --title "Noodle $app $version" --notes "$page"
    gh release edit "$channel" --repo "$repo" --draft=false --latest=false
else
    # Replace fixed-name downloads only on the mutable channel. Publish its feed
    # after the downloads and checksums upload successfully; immutable versioned releases are never replaced.
    gh release upload "$channel" "$assets/$archive" "$assets/$archive.sha256" "$assets/$disk_image" "$assets/$disk_image.sha256" --repo "$repo" --clobber
    gh release upload "$channel" "$assets/appcast.xml" --repo "$repo" --clobber
    gh release edit "$channel" --repo "$repo" --latest=false --title "Noodle $app $version" --notes "$page"
fi
