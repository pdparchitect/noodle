#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Opens Noodle in a scenario from Scenarios/, in a bundle of its own that cannot reach the network,
# an account or any other Noodle's data, and can photograph or record it.
set -euo pipefail

project_root="${0:A:h:h}"
app_name=Noodle
usage_command=scripts/scenario.sh
scenarios="$project_root/Scenarios"
build_root="$project_root/.build"
bundle_identifier="com.pdparchitect.noodle.scenarios"
entitlements="$build_root/NoodleScenarios.entitlements"
roots_key=NoodleScenariosRoot
signing_identity="${NOODLE_SIGNING_IDENTITY:-}"
# No share or tool extensions, no Agent Host and no shortcuts; none of the URL schemes, services or groups.
removed_paths=(PlugIns Extensions XPCServices/NoodleAgentHost.xpc Resources/Metadata.appintents)
removed_keys=(CFBundleURLTypes NSServices NoodleSharedGroup NoodleBrowserGroup NoodleAppletGroup NoodleComputerGroup)
benchmarks=true
build_source_app() { NOODLE_DATA_CONTAINER=development zsh "$project_root/scripts/xcode-build.sh" Noodle; }

source "$project_root/scripts/scenario-runner.zsh"
