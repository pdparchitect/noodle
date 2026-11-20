#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Builds Rook from the Xcode project Tuist generates from Project.swift and prints the app's path.
# ROOK_DATA_CONTAINER picks the identity: development is Rook Dev (Debug, the default), production
# is Rook (Release). Further arguments are build settings. The signed app lands in the repository's .build.
set -euo pipefail
rook_root="${0:A:h:h}"
project_root="${rook_root:h:h}"
# Every build shares one project, build folder and app, so one started while another runs waits for it rather than
# failing on the build's locked database.
if [[ -z "${ROOK_BUILD_LOCKED:-}" ]]; then
    mkdir -p "$project_root/.build"
    ROOK_BUILD_LOCKED=1 exec lockf -k "$project_root/.build/rook-build.lock" zsh "$0" "$@"
fi
case "${ROOK_DATA_CONTAINER:-development}" in
    development) configuration=Debug; app_name="Rook Dev" ;;
    production) configuration=Release; app_name="Rook" ;;
    *) print -u2 "ROOK_DATA_CONTAINER must be development or production."; exit 1 ;;
esac
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$rook_root" && "$tuist" generate --no-open >&2)
# Not Derived: that is Tuist's, and generating empties it.
derived_data="$project_root/.build/DerivedData/Rook"
zsh "$project_root/scripts/build-priority.sh" xcodebuild -workspace "$rook_root/Rook.xcworkspace" -scheme Rook \
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
