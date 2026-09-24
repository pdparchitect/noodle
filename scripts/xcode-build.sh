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
[[ -f "$project_root/$app/Project.swift" ]] || { print -u2 "$app has no Project.swift."; exit 1; }
container_setting="NOODLE_${(U)app}_DATA_CONTAINER"
case "${(P)container_setting:-${NOODLE_DATA_CONTAINER:-development}}" in
    development) configuration=Debug; app_name="Noodle $app Dev" ;;
    production) configuration=Release; app_name="Noodle $app" ;;
    tests) configuration=Tests; app_name="Noodle $app Tests" ;;
    *) print -u2 "$container_setting must be development, production or tests."; exit 1 ;;
esac
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$project_root/$app" && "$tuist" generate --no-open >&2)
xcodebuild -workspace "$project_root/$app/Noodle$app.xcworkspace" -scheme "Noodle$app" -configuration "$configuration" \
    -derivedDataPath "$project_root/$app/Derived" -destination 'platform=macOS' -allowProvisioningUpdates \
    -skipPackagePluginValidation -skipMacroValidation "$@" build >&2
destination="$project_root/.build/$app_name.app"
rm -rf "$destination"
ditto "$project_root/$app/Derived/Build/Products/$configuration/$app_name.app" "$destination"
codesign --verify --deep --strict "$destination"
print "$destination"
