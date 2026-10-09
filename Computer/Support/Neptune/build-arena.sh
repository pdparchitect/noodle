#!/bin/bash
# Offline, pinned Windows graphics build. Native libraries live only in each VM's helper.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
computer="$(cd "$here/../.." && pwd)"
output="${1:?Pass a build output directory}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
(cd "$computer" && shasum -a 256 -c "$here/runtime.sha256")
stamp="$(shasum -a 256 "$here/runtime.sha256" "$0" | shasum -a 256 | cut -c1-16)"
build="$output/$stamp"
if [ -f "$build/complete" ]; then printf '%s\n' "$build" > "$output/current"; exit 0; fi
rm -rf "$build"
mkdir -p "$build/tools/bin"
vendor="$computer/Vendor"
unzip -q "$vendor/meson-1.11.2-py3-none-any.whl" -d "$build/tools/python"
unzip -q -j "$vendor/ninja-1.13.0-py3-none-macosx_10_9_universal2.whl" 'ninja-1.13.0.data/scripts/ninja' -d "$build/tools/bin"
chmod +x "$build/tools/bin/ninja"
tar -xzf "$vendor/pyyaml-6.0.3.tar.gz" -C "$build/tools" pyyaml-6.0.3/lib/yaml
cp -R "$build/tools/pyyaml-6.0.3/lib/yaml" "$build/tools/python/yaml"
printf '#!/bin/sh\nexec /usr/bin/python3 -m mesonbuild.mesonmain "$@"\n' > "$build/tools/bin/meson"
out="$build/out"
printf '#!/bin/sh\ncase "$*" in\n--version) echo 0.29.2 ;;\n*--modversion*epoxy*) echo 1.5.9 ;;\n*--variable=epoxy_has_egl*epoxy*) echo 1 ;;\n*--cflags*epoxy*) echo "-I%s/include" ;;\n*--libs*epoxy*) echo "-L%s/lib -lepoxy" ;;\n*epoxy*) exit 0 ;;\n*) exit 1 ;;\nesac\n' "$out" "$out" > "$build/tools/bin/pkg-config"
chmod +x "$build/tools/bin/meson" "$build/tools/bin/pkg-config"
for archive in libepoxy-neptune-bf98587477fe virglrenderer-neptune-5d26f605f50f neptune-dependencies-20261009; do
    tar -xzf "$vendor/$archive.tar.gz" -C "$build"
done
patch -s -p1 -d "$build/libepoxy" < "$here/epoxy.patch"
patch -s -p1 -d "$build/renderer" < "$here/angle.patch"
patch -s -p1 -d "$build/renderer" < "$here/arena.patch"
(cd "$build/dependencies/neptune-guest" && shasum -a 256 -c "$here/guest.sha256")
export PATH="$build/tools/bin:/usr/bin:/bin" PYTHONPATH="$build/tools/python"
export CFLAGS="-arch arm64 -mmacosx-version-min=26.0 -I$build/dependencies/include"
export LDFLAGS="-arch arm64 -mmacosx-version-min=26.0"
meson setup "$build/epoxy-build" "$build/libepoxy" --prefix="$out" --buildtype=release -Degl=yes -Dglx=no -Dx11=false -Dtests=false -Ddocs=false
ninja -C "$build/epoxy-build" install
LDFLAGS="$LDFLAGS -framework CoreFoundation" meson setup "$build/renderer-build" "$build/renderer" --prefix="$out" --buildtype=release \
    -Dplatforms=egl -Dvenus=false -Dneptune=true -Drender-server-mode=thread -Dcheck-gl-errors=false
ninja -C "$build/renderer-build" install
touch "$build/complete"
printf '%s\n' "$build" > "$output/current"
