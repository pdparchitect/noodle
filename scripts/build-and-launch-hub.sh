#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
[[ $# == 0 ]] || { print -u2 'Usage: scripts/build-and-launch-hub.sh (isolated development only)'; exit 1; }
# Debug is Noodle Hub Dev, with its own identity and data. Open Hub/NoodleHub.xcworkspace to debug.
tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
(cd "$project_root/Hub" && "$tuist" generate --no-open >&2)
xcodebuild -workspace "$project_root/Hub/NoodleHub.xcworkspace" -scheme NoodleHub -configuration Debug \
    -derivedDataPath "$project_root/Hub/Derived" -destination 'platform=macOS' -allowProvisioningUpdates \
    -skipPackagePluginValidation -skipMacroValidation build >&2
app="$project_root/Hub/Derived/Build/Products/Debug/Noodle Hub Dev.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == com.pdparchitect.noodle.hub.local ]] || {
    print -u2 'Refusing to launch a non-development Hub bundle.'; exit 1
}
open "$app"
print "Built and launched $app"
