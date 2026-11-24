#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Another product's images, such as Rook's, pass their own name and version file.
prefix="${IMAGE_PREFIX:-noodle-computer}"
version="$(tr -d '[:space:]' < "${IMAGE_VERSION_FILE:-Computer/Images/VERSION}")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
# Check both packages before writing either. Retries only accept identical builds.
python3 scripts/computer-image-registry.py preflight
for kind in shell desktop; do
    image="ghcr.io/pdparchitect/$prefix-$kind-image:$version"
    docker tag "$prefix-$kind-image:check" "$image"
    docker push "$image"
done
for kind in shell desktop; do
    image="ghcr.io/pdparchitect/$prefix-$kind-image:latest"
    docker tag "$prefix-$kind-image:check" "$image"
    docker push "$image"
done
python3 scripts/computer-image-registry.py verify > computer-image-digests.txt
cat computer-image-digests.txt >> "$GITHUB_STEP_SUMMARY"
