#!/bin/zsh
# Builds an app from the Xcode project Tuist generates from APP/Project.swift and prints its path.
# The app's data container picks the identity, as for every app: NOODLE_<APP>_DATA_CONTAINER, else
# NOODLE_DATA_CONTAINER. Development is the Dev app (Debug), production the released one (Release) and
# tests an app's isolated test identity (Tests), where it has one. Further arguments are build settings.
# The signed app lands in .build, where launchers and checks find it. Releases use package-xcode-release.sh.
set -euo pipefail
project_root="${0:A:h:h}"
app="${1:?Usage: scripts/xcode-build.sh APP [SETTING=VALUE ...]}"
shift
# Noodle's project is the repository's own; each companion's is in its folder.
if [[ "$app" == Noodle ]]; then folder="$project_root"; name=Noodle; else folder="$project_root/$app"; name="Noodle $app"; fi
[[ -f "$folder/Project.swift" ]] || { print -u2 "$app has no Project.swift."; exit 1; }
container_setting="NOODLE_${(U)app}_DATA_CONTAINER"
[[ "$app" != Noodle ]] || container_setting=NOODLE_DATA_CONTAINER
case "${(P)container_setting:-${NOODLE_DATA_CONTAINER:-development}}" in
    development) configuration=Debug; app_name="$name Dev" ;;
    production) configuration=Release; app_name="$name" ;;
    tests) configuration=Tests; app_name="$name Tests" ;;
    *) print -u2 "$container_setting must be development, production or tests."; exit 1 ;;
esac
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$folder" && "$tuist" generate --no-open >&2)
# Not $folder/Derived: that is Tuist's, and generating empties it, which would rebuild everything each time.
derived_data="$project_root/.build/DerivedData/$app"
xcodebuild -workspace "$folder/${name// /}.xcworkspace" -scheme "${name// /}" -configuration "$configuration" \
    -derivedDataPath "$derived_data" -destination 'platform=macOS' -allowProvisioningUpdates \
    -skipPackagePluginValidation -skipMacroValidation "$@" build >&2
destination="$project_root/.build/$app_name.app"
rm -rf "$destination"
ditto "$derived_data/Build/Products/$configuration/$app_name.app" "$destination"
codesign --verify --deep --strict "$destination"
print "$destination"
