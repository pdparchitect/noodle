#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
fixture_build="$project_root/.build/conversation-annotations"
export CLANG_MODULE_CACHE_PATH="$fixture_build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --package-path "$project_root" --scratch-path "$fixture_build" --jobs 4 --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --scratch-path "$fixture_build" --show-bin-path)"
fixture_app="$fixture_build/Noodle Conversation Annotation Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
preview_support=()
if [[ -f "$project_root/Sources/Noodle/NoodletPreviewAccess.swift" ]]; then
    preview_support+=("$project_root/Sources/Noodle/NoodletPreviewAccess.swift")
fi
swiftc -parse-as-library -target "$(uname -m)-apple-macosx15.0" -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/KeyboardBindings.swift" \
    "$project_root/Sources/Noodle/AnnotationCommands.swift" \
    "$project_root/Sources/Noodle/AttachmentPreviewController.swift" \
    "$project_root/Sources/Noodle/AnnotationPopover.swift" \
    "$project_root/Sources/Noodle/AnnotationContent.swift" \
    "$project_root/Sources/Noodle/AnnotationPreview.swift" \
    "$project_root/Sources/Noodle/CaptureAttachment.swift" \
    "${preview_support[@]}" \
    "$project_root/Sources/Noodle/MessageMarkdownCache.swift" \
    "$project_root/Sources/Noodle/ConversationAnnotation.swift" \
    "$project_root/Sources/Noodle/ConversationAnnotationContent.swift" \
    "$project_root/Tests/NativeFixtureChecks.swift" \
    "$project_root/Tests/conversation-annotations.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o "$bin_path"/AppletBridge.build/*.swift.o \
    -o "$fixture_app/Contents/MacOS/ConversationAnnotationTests"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pdparchitect.noodle.conversation-annotation-tests</string>
<key>CFBundleName</key><string>Noodle Conversation Annotation Tests</string>
<key>CFBundleExecutable</key><string>ConversationAnnotationTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$project_root/Tests/attachment-annotations.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
codesign -d --entitlements :- "$fixture_app"
if otool -L "$fixture_app/Contents/MacOS/ConversationAnnotationTests" | rg -q '/opt/homebrew|/usr/local'; then
    print -u2 "Capture tests must only link bundled code and system libraries."
    exit 1
fi
if [[ "${1:-}" = "--build-only" ]]; then exit 0; fi
test_log="$fixture_build/native-tests.log"
: > "$test_log"
"$fixture_app/Contents/MacOS/ConversationAnnotationTests" > "$test_log" 2>&1 || { cat "$test_log"; exit 1; }
cat "$test_log"
rg -q '^PASS: conversation annotations' "$test_log"
