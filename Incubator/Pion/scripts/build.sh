#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Builds Pion from the Xcode project Tuist generates from Project.swift and prints the app's path.
# PION_DATA_CONTAINER picks the identity: development is Pion Dev (Debug, the default), production
# is Pion (Release). Further arguments are build settings. The signed app lands in the repository's .build.
set -euo pipefail
pion_root="${0:A:h:h}"
project_root="${pion_root:h:h}"
case "${PION_DATA_CONTAINER:-development}" in
    development) configuration=Debug; app_name="Pion Dev" ;;
    production) configuration=Release; app_name="Pion" ;;
    *) print -u2 "PION_DATA_CONTAINER must be development or production."; exit 1 ;;
esac
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$pion_root" && "$tuist" generate --no-open >&2)
# Not Derived: that is Tuist's, and generating empties it.
derived_data="$project_root/.build/DerivedData/Pion"
zsh "$project_root/scripts/build-priority.sh" xcodebuild -workspace "$pion_root/Pion.xcworkspace" -scheme Pion \
    -configuration "$configuration" -derivedDataPath "$derived_data" -destination 'platform=macOS' \
    -allowProvisioningUpdates ARCHS=arm64 -skipPackagePluginValidation -skipMacroValidation "$@" build >&2
built="$derived_data/Build/Products/$configuration/$app_name.app"
destination="$project_root/.build/$app_name.app"
# Copied beside it and swapped in, so the previous build stays whole until the new one is.
incoming="$destination.incoming" outgoing="$destination.outgoing"
[[ -n "$app_name" && -d "$built" ]] || { print -u2 "xcodebuild made no $built."; exit 1; }
rm -rf -- "$incoming" "$outgoing"
ditto "$built" "$incoming"
codesign --verify --deep --strict "$incoming"
[[ ! -e "$destination" ]] || mv "$destination" "$outgoing"
mv "$incoming" "$destination"
rm -rf -- "$outgoing"
print "$destination"
