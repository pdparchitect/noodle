#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
app="$("$project_root/scripts/build-app.sh")"
open "$app"
print "Built and launched $app"
