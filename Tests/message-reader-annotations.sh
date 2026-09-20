#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --build-system native --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --build-system native --package-path "$project_root" --show-bin-path)"
core_objects=("${(@f)$(python3 "$project_root/Tests/core-link-objects.py" "$bin_path")}")
fixture_app="$project_root/.build/Message Reader Annotation Tests.app"
mkdir -p "$fixture_app/Contents/MacOS"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx26.0" -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/KeyboardBindings.swift" \
    "$project_root/Sources/Noodle/AnnotationCommands.swift" \
    "$project_root/Sources/Noodle/AttachmentPreviewController.swift" \
    "$project_root/Sources/Noodle/AnnotationPopover.swift" \
    "$project_root/Sources/Noodle/AnnotationContent.swift" \
    "$project_root/Sources/Noodle/AnnotationPreview.swift" \
    "$project_root/Sources/Noodle/CaptureAttachment.swift" \
    "$project_root/Sources/Noodle/NoodletPreviewAccess.swift" \
    "$project_root/Sources/Noodle/MessageMarkdownCache.swift" \
    "$project_root/Sources/Noodle/ConversationAnnotation.swift" \
    "$project_root/Sources/Noodle/ConversationAnnotationContent.swift" \
    "$project_root/Sources/Noodle/LongMessageText.swift" \
    "$project_root/Tests/NativeFixtureChecks.swift" \
    "$project_root/Tests/message-reader-annotations.swift" \
    "${core_objects[@]}" -o "$fixture_app/Contents/MacOS/MessageReaderAnnotationTests"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.pdparchitect.noodle.reader-annotation-tests</string>
<key>CFBundleName</key><string>Message Reader Annotation Tests</string>
<key>CFBundleExecutable</key><string>MessageReaderAnnotationTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>CFBundleVersion</key><string>1</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --options runtime --entitlements "$project_root/Tests/attachment-annotations.entitlements" "$fixture_app"
codesign --verify --strict "$fixture_app"
if otool -L "$fixture_app/Contents/MacOS/MessageReaderAnnotationTests" | rg -q '/opt/homebrew|/usr/local'; then
    print -u2 "Reader tests must only link bundled code and system libraries."
    exit 1
fi
test_log="$(mktemp /tmp/noodle-reader-annotations.XXXXXX)"
trap 'rm -f "$test_log"' EXIT
open -n -W --stdout "$test_log" --stderr "$test_log" "$fixture_app"
cat "$test_log"
rg -q '^PASS: reader annotations' "$test_log"
