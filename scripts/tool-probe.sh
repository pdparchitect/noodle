#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Runs one of Noodle's catalogue tools against its real service with the sign-in Noodle keeps; pass
# --namespace com.pdparchitect.noodle.hub for a Noodle Hub's on this Mac. See NoodleToolProbe.
set -euo pipefail
root="${0:A:h:h}"
zsh "$root/scripts/build-priority.sh" swift build --package-path "$root" --product noodle-tool-probe >&2
exec "$(swift build --package-path "$root" --show-bin-path)/noodle-tool-probe" "$@"
