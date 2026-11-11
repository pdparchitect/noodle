#!/bin/zsh
# Publishes Noodle Server's prepared release from dist/server-VERSION: the immutable server-vVERSION
# release, then the server-latest channel whose fixed-name downloads the README links to.
set -euo pipefail
project_root="${0:A:h:h}"
version="${1:?Usage: scripts/publish-server-release.sh VERSION NOTES}"
notes="${2:?Pass the release notes file}"
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || exit 1
[[ "$version" == "$(tr -d '[:space:]' < "$project_root/Server/VERSION")" ]] || exit 1
tag="server-v$version"
channel="server-latest"
repo="pdparchitect/noodle"
assets="$project_root/dist/server-$version"
files=()
for arch in arm64 x86_64; do
    archive="Noodle-Server-linux-$arch.tar.gz"
    [[ -s "$assets/$archive" && -s "$assets/$archive.sha256" ]]
    (cd "$assets"; sha256sum -c "$archive.sha256")
    files+=("$assets/$archive" "$assets/$archive.sha256")
done
[[ -s "$notes" ]]
[[ "$(gh api "repos/$repo" --jq .private)" == false ]]
# Refuse to replace immutable published assets, or regress the stable channel.
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    print -u2 "Release $tag already exists. Do not overwrite published archives; inspect and repair a failed promotion separately."; exit 1
fi
channel_title="$(gh release view "$channel" --repo "$repo" --json name --jq .name 2>/dev/null || true)"
if [[ -n "$channel_title" ]]; then
    previous="${channel_title#Noodle Server }"
    [[ "$previous" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Unrecognized Server channel version'; exit 1; }
    autoload -Uz is-at-least
    is-at-least "$previous" "$version" || { print -u2 'Refusing to roll back the Server channel'; exit 1; }
fi
gh release create "$tag" "${files[@]}" \
    --repo "$repo" --verify-tag --draft --latest=false --title "Noodle Server $version" --notes-file "$notes"
gh release edit "$tag" --repo "$repo" --draft=false --latest=false

# The channel is a marker, not a version tag, and never becomes the repository's latest release.
download="https://github.com/$repo/releases/download/$channel/Noodle-Server-linux"
page="Noodle Server $version. Download for Linux on [arm64]($download-arm64.tar.gz) · [x86_64]($download-x86_64.tar.gz) · [Release notes](https://github.com/$repo/releases/tag/$tag)"
if [[ -z "$channel_title" ]]; then
    gh release create "$channel" "${files[@]}" \
        --repo "$repo" --target "$(git -C "$project_root" rev-parse "$tag^{commit}")" \
        --draft --latest=false --title "Noodle Server $version" --notes "$page"
    gh release edit "$channel" --repo "$repo" --draft=false --latest=false
else
    gh release upload "$channel" "${files[@]}" --repo "$repo" --clobber
    gh release edit "$channel" --repo "$repo" --latest=false --title "Noodle Server $version" --notes "$page"
fi
