#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Opens Pion in a scenario from Scenarios/, in a bundle of its own that cannot reach the network,
# an account or any other Pion's data, and can photograph or record it. Noodle's runner does the work.
set -euo pipefail

pion_root="${0:A:h:h}"
project_root="${pion_root:h:h}"
app_name=Pion
usage_command=Incubator/Pion/scripts/scenario.sh
scenarios="$pion_root/Scenarios"
build_root="$project_root/.build"
bundle_identifier="com.pdparchitect.pion.scenarios"
entitlements="$build_root/PionScenarios.entitlements"
roots_key=PionScenariosRoot
signing_identity="${PION_SIGNING_IDENTITY:-}"
# Nothing that runs a harness: no Agent Host and no helpers, as scenario agents are scripted. No Send to Pion or
# Shortcuts actions either, which would offer the scenarios bundle in every Share menu and in Shortcuts.
removed_paths=(XPCServices Helpers PlugIns Resources/Metadata.appintents)
removed_keys=(CFBundleURLTypes NoodleAgentHostService NoodleApplicationIdentifier NoodleSharedGroup NSServices)
benchmarks=false
build_source_app() { zsh "$pion_root/scripts/build.sh"; }

source "$project_root/scripts/scenario-runner.zsh"
