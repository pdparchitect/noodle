#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Runs one of Pion's tools against its real service with the sign-in or key Pion keeps; see NoodleToolProbe.
set -euo pipefail
pion_root="${0:A:h:h}"
zsh "$pion_root/../../scripts/build-priority.sh" swift build --package-path "$pion_root" --product pion-tool-probe >&2
exec "$(swift build --package-path "$pion_root" --show-bin-path)/pion-tool-probe" "$@"
