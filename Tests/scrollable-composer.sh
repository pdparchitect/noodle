#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --disable-sandbox --package-path "$project_root" --target NoodleCore
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swiftc -parse-as-library -I "$bin_path/Modules" \
    "$project_root/Sources/Noodle/BotAvatar.swift" \
    "$project_root/Sources/Noodle/ComposerNameCompletion.swift" \
    "$project_root/Sources/Noodle/ScrollableChatComposer.swift" \
    "$project_root/Sources/Noodle/ComposerFocusSurface.swift" \
    "$project_root/Tests/scrollable-composer.swift" \
    "$bin_path"/NoodleCore.build/*.swift.o "$bin_path"/NoodleWallpaperCore.build/*.swift.o \
    "$bin_path"/ComputerBridge.build/*.swift.o "$bin_path"/AppletBridge.build/*.swift.o \
    -o "$project_root/.build/ScrollableComposerChecks"
"$project_root/.build/ScrollableComposerChecks" "$@"
