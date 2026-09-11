#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
# Keep raw swiftc linking independent of concurrent app/coverage builds, which
# can otherwise rewrite the object files after SwiftPM releases its build lock.
fixture_build="$project_root/.build/annotation-fixture"
swift build --disable-sandbox --package-path "$project_root" --scratch-path "$fixture_build" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --scratch-path "$fixture_build" --show-bin-path)"
fixture_app="$project_root/.build/Noodle Annotation Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx15.0" -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/AttachmentPreviewController.swift" \
    "$project_root/Sources/Noodle/AnnotationPopover.swift" \
    "$project_root/Sources/Noodle/AnnotationContent.swift" \
    "$project_root/Sources/Noodle/AnnotationPreview.swift" \
    "$project_root/Tests/NativeFixtureChecks.swift" \
    "$project_root/Tests/AnnotationContentChecks.swift" \
    "$project_root/Tests/AnnotationVisualChecks.swift" \
    "$project_root/Tests/attachment-annotations.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o \
    -o "$fixture_app/Contents/MacOS/AnnotationTests"
cp "$project_root/Tests/attachment-annotations-Info.plist" "$fixture_app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$project_root/Tests/attachment-annotations.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
codesign -d --entitlements :- "$fixture_app"
if otool -L "$fixture_app/Contents/MacOS/AnnotationTests" | rg -q '/opt/homebrew|/usr/local'; then
    print -u2 "The fixture must not link against mutable external libraries."
    exit 1
fi
if [[ "${1:-}" = "--build-only" ]]; then
    exit 0
fi
test_log="$(mktemp /tmp/noodle-annotations.XXXXXX)"
trap 'rm -f "$test_log"' EXIT
if [[ "${1:-}" = "--headless" ]]; then
    "$fixture_app/Contents/MacOS/AnnotationTests" "$@" > "$test_log" 2>&1 || { cat "$test_log"; exit 1; }
else
    open -W --stdout "$test_log" --stderr "$test_log" "$fixture_app" --args "$@"
fi
cat "$test_log"
rg -q '^PASS: Quick Look annotations' "$test_log"
