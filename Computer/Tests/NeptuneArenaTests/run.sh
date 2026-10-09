#!/bin/zsh
# A renderer protocol regression, independent of Windows, VZ, and a graphics device.
# Usage: zsh run.sh renderer-source renderer-build [library-path]
set -euo pipefail
source="${1:?Pass the renderer source directory}"
build="${2:?Pass the renderer build directory}"
library="${3:-$build/src/libvirglrenderer.1.dylib}"
here="${0:A:h}"
cc -DHAVE_CONFIG_H=1 -I"$source/src" -I"$source/src/neptune" \
    -I"$source/src/mesa" -I"$source/src/mesa/compat" -I"$build" -I"$build/src" \
    -I"$source/src/gallium/include" -I"$source/src/gallium/auxiliary" \
    "$here/arena.c" "$library" -Wl,-rpath,"${library:A:h}" -o "$build/arena-test"
"$build/arena-test"
