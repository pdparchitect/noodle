#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
output="${1:?Pass the helper output directory}"
source_root="${output:A:h:h}/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
if [[ ! -d "$source_root" ]]; then
    source_root="$project_root/.build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal"
fi
[[ -d "$source_root" ]] || { print -u2 "Resolve Swift package dependencies first."; exit 1; }

component="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null || true)"
# Xcode omits toolchainSearchPath when its Metal component is uninstalled.
# Let the executable check below report the installation command in that case.
toolchain="$(print -r -- "$component" | plutil -extract toolchainSearchPath raw -o - - 2>/dev/null || true)"
metal="$toolchain/Metal.xctoolchain/usr/bin/metal"
metallib="$toolchain/Metal.xctoolchain/usr/bin/metallib"
[[ -x "$metal" && -x "$metallib" ]] || {
    print -u2 "Install Apple's Metal Toolchain with: xcodebuild -downloadComponent MetalToolchain"
    exit 1
}
sdk="${NOODLE_MACOS_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
if [[ -z "${NOODLE_MACOS_SDK:-}" && -d /Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk ]]; then
    sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk
fi
cache="$project_root/.build/mlx-metal"
mkdir -p "$cache" "$output"
fingerprint="$(cat "$project_root/Package.resolved"; "$metal" --version; print -r -- "$sdk")"
if [[ -f "$cache/fingerprint" && -f "$cache/mlx.metallib" && "$(cat "$cache/fingerprint")" == "$fingerprint" ]]; then
    cp "$cache/mlx.metallib" "$output/mlx.metallib"
    exit 0
fi
air_files=()
for source in "$source_root"/**/*.metal(N); do
    relative="${source#$source_root/}"
    air="$cache/${relative//\//_}.air"
    "$metal" -c -target air64-apple-macos14.0 -isysroot "$sdk" \
        -fmetal-math-mode=fast -fmetal-math-fp32-functions=fast "$source" -o "$air"
    air_files+=("$air")
done
(( ${#air_files} > 0 ))
"$metallib" "${air_files[@]}" -o "$cache/mlx.metallib"
print -r -- "$fingerprint" > "$cache/fingerprint"
cp "$cache/mlx.metallib" "$output/mlx.metallib"
