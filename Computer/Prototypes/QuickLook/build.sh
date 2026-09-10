#!/bin/zsh
set -euo pipefail
source_root="${0:A:h}"
proof_root="$(mktemp -d /tmp/noodle-preview-proof.XXXXXX)"
proof_app="$proof_root/Computer Preview Proof.app"
proof_extension="$proof_app/Contents/PlugIns/Preview.appex"
mkdir -p "$proof_app/Contents/MacOS" "$proof_extension/Contents/MacOS"
swiftc -parse-as-library "$source_root/Host.swift" -o "$proof_app/Contents/MacOS/PreviewProof"
swiftc -parse-as-library -application-extension -Xlinker -e -Xlinker _NSExtensionMain \
    "$source_root/Preview.swift" -o "$proof_extension/Contents/MacOS/PreviewExtension"
cp "$source_root/Host-Info.plist" "$proof_app/Contents/Info.plist"
cp "$source_root/Preview-Info.plist" "$proof_extension/Contents/Info.plist"
proof_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ { print $2; exit }')"
[[ -n "$proof_identity" ]]
for bundle in "$proof_extension" "$proof_app"; do
    codesign --force --options runtime --timestamp=none --entitlements "$source_root/Proof.entitlements" --sign "$proof_identity" "$bundle"
done
codesign --verify --deep --strict "$proof_app"
print "$proof_app"
