#!/bin/zsh
set -euo pipefail

# Use a newer installed command-line SDK for the Apple harness without changing
# xcode-select or the developer's global toolchain. Full Xcode still supplies
# app packaging and XCTest. Explicit overrides take precedence.
noodle_swift="${NOODLE_SWIFT:-$(command -v swift)}"
noodle_xcode_sdk="$(xcrun --sdk macosx --show-sdk-path)"
noodle_sdk="${NOODLE_MACOS_SDK:-$noodle_xcode_sdk}"
noodle_sdk_major="${${noodle_sdk:t}#MacOSX}"
noodle_sdk_major="${noodle_sdk_major%%.*}"
if [[ -z "${NOODLE_SWIFT:-}" && -z "${NOODLE_MACOS_SDK:-}" &&
      "$noodle_sdk_major" == <-> && "$noodle_sdk_major" -lt 27 &&
      -d /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk &&
      -x /Library/Developer/CommandLineTools/usr/bin/swift ]]; then
    noodle_swift=/Library/Developer/CommandLineTools/usr/bin/swift
    noodle_sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk
fi
# Direct toolchain executables bypass xcrun's environment setup. SwiftPM's
# --sdk alone does not give Clang the SDK version: it can record macOS 15.0
# (the deployment target) and select legacy SwiftUI behavior in a new build.
# Keep the SDK environment consistent for manifests, compilation, and linking.
export SDKROOT="$noodle_sdk"
noodle_scratch_args=()
if [[ "$noodle_sdk" != "$noodle_xcode_sdk" ]]; then
    export NOODLE_APPLE_HARNESS_ONLY=1
    # Keep the helper's normal SwiftPM cache separate from the app's Xcode
    # module cache, including when called by build-app.sh.
    unset CLANG_MODULE_CACHE_PATH SWIFTPM_MODULECACHE_OVERRIDE
    noodle_scratch="${0:A:h:h}/.build/apple27"
    noodle_explicit_scratch=false
    for noodle_argument in "$@"; do
        if [[ "$noodle_argument" == --scratch-path || "$noodle_argument" == --scratch-path=* ]]; then
            noodle_explicit_scratch=true
        fi
    done
    if [[ "$noodle_explicit_scratch" == false ]]; then
        noodle_scratch_args=(--scratch-path "$noodle_scratch")
        export NOODLE_APPLE_TEST_HELPER="${NOODLE_APPLE_TEST_HELPER:-$noodle_scratch/debug/NoodleAppleAgent}"
    fi
fi

# Some Xcode versions report the component installed but fail to resolve its
# metal shim after an OS upgrade. Use the installed, Apple-managed toolchain.
noodle_metal_json="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null || true)"
noodle_metal_root="$(print -r -- "$noodle_metal_json" | plutil -extract toolchainSearchPath raw -o - - 2>/dev/null || true)"
if [[ -x "$noodle_metal_root/Metal.xctoolchain/usr/bin/metal" ]]; then
    export PATH="$noodle_metal_root/Metal.xctoolchain/usr/bin:$PATH"
fi

noodle_command="${1:?Pass build, test, run, or package}"
shift
if [[ "$noodle_command" == package ]]; then
    exec "$noodle_swift" "$noodle_command" --sdk "$noodle_sdk" "${noodle_scratch_args[@]}" "$@"
fi
# Swift Build currently chooses the selected Xcode SDK despite --sdk. The
# native engine honors this mixed-installation override and XCTest search paths.
noodle_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$noodle_developer" == *.app ]]; then
    noodle_developer="$noodle_developer/Contents/Developer"
fi
noodle_plugins="$noodle_developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
noodle_plugin_server="$noodle_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-plugin-server"
noodle_plugin_args=()
if [[ -d "$noodle_plugins" && -x "$noodle_plugin_server" ]]; then
    # CLT omits the platform macros. Run the selected Xcode's macros with its
    # matching plugin server, which communicates with Swift over a stable protocol.
    # Do not replace SwiftMacros: the compiler must use its own matching version.
    noodle_macro_links="${0:A:h:h}/.build/apple-platform-macros"
    mkdir -p "$noodle_macro_links"
    for noodle_macro in FoundationModelsMacros AppIntentsMacros FoundationMacros ObservationMacros SwiftUIMacros; do
        if [[ -f "$noodle_plugins/lib${noodle_macro}.dylib" ]]; then
            noodle_macro_link="$noodle_macro_links/lib${noodle_macro}.dylib"
            if [[ "$(readlink "$noodle_macro_link" 2>/dev/null || true)" != "$noodle_plugins/lib${noodle_macro}.dylib" ]]; then
                ln -sf "$noodle_plugins/lib${noodle_macro}.dylib" "$noodle_macro_link"
            fi
        fi
    done
    noodle_plugin_args=(-Xswiftc -external-plugin-path -Xswiftc "$noodle_macro_links#$noodle_plugin_server")
fi
# Include the linker sysroot in the build key as well. Changing SDKROOT alone
# does not invalidate executables previously linked with the incorrect version.
exec "$noodle_swift" "$noodle_command" --build-system native --sdk "$noodle_sdk" "${noodle_scratch_args[@]}" "${noodle_plugin_args[@]}" \
    -Xlinker -syslibroot -Xlinker "$noodle_sdk" "$@"
