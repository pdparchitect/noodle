#!/bin/bash
# Host-only regressions; no VM, graphics device, account, or network is required.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
computer="$(cd "$here/../.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/noodle-neptune-tests.XXXXXX")"
trap 'rm -rf "$build"' EXIT
swiftc -module-cache-path "$build/cache" "$computer/Sources/NeptuneTransport/NeptuneMessage.swift" "$here/transport.swift" -o "$build/transport"
"$build/transport"
clang -I "$computer/Sources/NeptunePOSIX/include" -c "$computer/Sources/NeptunePOSIX/NeptunePOSIX.c" -o "$build/posix.o"
swiftc -module-cache-path "$build/cache" -I "$computer/Sources/NeptunePOSIX/include" "$computer/Sources/NeptuneTransport/NeptuneMemory.swift" "$here/memory.swift" "$build/posix.o" -o "$build/memory"
"$build/memory"
swiftc -module-cache-path "$build/cache" "$computer/Sources/NoodleComputer/WindowsGraphicsStartup.swift" "$here/startup.swift" -o "$build/startup"
"$build/startup"
swiftc -module-cache-path "$build/cache" "$computer/Sources/NoodleComputer/NeptuneScanout.swift" "$here/scanout.swift" -o "$build/scanout"
"$build/scanout"
mkdir -p "$build/Metadata.app/Contents/MacOS"
cat > "$build/Metadata.app/Contents/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>noodle.metadata.test</string><key>CFBundleExecutable</key><string>parent</string><key>NoodleGPUGroup</key><string>noodle-test</string></dict></plist>
XML
cat > "$build/helper.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>LSBackgroundOnly</key><true/></dict></plist>
XML
swiftc -module-cache-path "$build/cache" "$computer/Sources/NoodleWindowsRenderer/NativeNeptuneLibrary.swift" "$here/location.swift" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$build/helper.plist" -o "$build/Metadata.app/Contents/MacOS/helper"
"$build/Metadata.app/Contents/MacOS/helper"
