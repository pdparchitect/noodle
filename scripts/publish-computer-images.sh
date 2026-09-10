#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version="$(tr -d '[:space:]' < Computer/Images/VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
# Check both packages before writing either. Retries only accept identical builds.
python3 scripts/computer-image-registry.py preflight
for kind in shell desktop; do
    image="ghcr.io/pdparchitect/noodle-computer-$kind-image:$version"
    docker tag "noodle-computer-$kind-image:check" "$image"
    docker push "$image"
done
for kind in shell desktop; do
    image="ghcr.io/pdparchitect/noodle-computer-$kind-image:latest"
    docker tag "noodle-computer-$kind-image:check" "$image"
    docker push "$image"
done
python3 scripts/computer-image-registry.py verify > computer-image-digests.txt
cat computer-image-digests.txt >> "$GITHUB_STEP_SUMMARY"
