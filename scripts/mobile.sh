#!/bin/zsh
# Tests, packages and uploads the phone app, from the Xcode project Tuist generates from Mobile/Project.swift.
#   test                       runs its tests on an iPhone simulator
#   package VERSION BUILD DIR  archives a release and exports Noodle-Mobile.ipa and its checksum into DIR
#   upload IPA                 sends a packaged app to App Store Connect, where TestFlight picks it up
# package and upload sign in with the App Store Connect key in APPLE_API_KEY_PATH, APPLE_API_KEY_ID and
# APPLE_API_ISSUER_ID. The archive is unsigned; the export signs it with Apple's cloud-managed
# distribution certificate, so no certificate is installed and none is created per run.
set -euo pipefail
project_root="${0:A:h:h}"
folder="$project_root/Mobile"
command="${1:?Usage: scripts/mobile.sh test | package VERSION BUILD DIR | upload IPA}"
shift

generate() {
    local tuist
    tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
    (cd "$folder" && "$tuist" generate --no-open >&2)
}

require_key() {
    : "${APPLE_API_KEY_PATH:?Missing App Store Connect key}"
    : "${APPLE_API_KEY_ID:?Missing App Store Connect key ID}"
    : "${APPLE_API_ISSUER_ID:?Missing App Store Connect issuer}"
}

case "$command" in
    test)
        simulator="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
print(next((d["udid"] for runtime, found in sorted(devices.items(), reverse=True) if ".iOS-" in runtime
            for d in found if d["name"].startswith("iPhone")), ""))')"
        [[ -n "$simulator" ]] || { print -u2 "No iPhone simulator is installed; run: xcodebuild -downloadPlatform iOS"; exit 1; }
        generate
        xcodebuild -workspace "$folder/NoodleMobile.xcworkspace" -scheme NoodleMobile -configuration Debug \
            -derivedDataPath "$folder/Derived" -destination "id=$simulator" test
        ;;
    package)
        version="${1:?Missing version}" build="${2:?Missing build number}" output="${3:?Missing output folder}"
        [[ "$(tr -d '[:space:]' < "$folder/VERSION")" == "$version" ]] || { print -u2 "Mobile/VERSION is not $version."; exit 1; }
        require_key
        generate
        archive="$folder/Derived/NoodleMobile.xcarchive"
        rm -rf "$archive" "$output"
        xcodebuild -workspace "$folder/NoodleMobile.xcworkspace" -scheme NoodleMobile -configuration Release \
            -derivedDataPath "$folder/Derived" -destination 'generic/platform=iOS' -archivePath "$archive" \
            CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION="$build" archive
        xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output" \
            -exportOptionsPlist "$folder/Support/ExportOptions.plist" -allowProvisioningUpdates \
            -authenticationKeyPath "$APPLE_API_KEY_PATH" -authenticationKeyID "$APPLE_API_KEY_ID" \
            -authenticationKeyIssuerID "$APPLE_API_ISSUER_ID"
        ipa=("$output"/*.ipa)
        (( ${#ipa} == 1 )) || { print -u2 "Expected one exported app in $output."; exit 1; }
        mv "$ipa[1]" "$output/Noodle-Mobile.ipa"
        (cd "$output" && shasum -a 256 Noodle-Mobile.ipa > Noodle-Mobile.ipa.sha256)
        print "$output/Noodle-Mobile.ipa"
        ;;
    upload)
        ipa="${1:?Missing app}"
        (cd "${ipa:h}" && shasum -a 256 -c "${ipa:t}.sha256")
        require_key
        xcrun altool --upload-app -f "$ipa" -t ios --api-key "$APPLE_API_KEY_ID" \
            --api-issuer "$APPLE_API_ISSUER_ID" --p8-file-path "$APPLE_API_KEY_PATH"
        ;;
    *)
        print -u2 "Unknown command: $command"
        exit 1
        ;;
esac
