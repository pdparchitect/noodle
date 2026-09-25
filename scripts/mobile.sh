#!/bin/zsh
# Tests, packages and uploads the phone app, from the Xcode project Tuist generates from Mobile/Project.swift.
#   run                        builds Noodle Dev and opens it on an iPhone simulator
#   test                       runs its tests on an iPhone simulator
#   package VERSION BUILD DIR  archives a release, exports Noodle-Mobile.ipa and its checksum into DIR and
#                              has App Store Connect validate it
#   upload IPA                 sends a packaged app to App Store Connect, where TestFlight picks it up
# package and upload sign in with the App Store Connect key in APPLE_API_KEY_PATH, APPLE_API_KEY_ID and
# APPLE_API_ISSUER_ID. The archive is unsigned; the export signs it with Apple's cloud-managed
# distribution certificate, so no certificate is installed and none is created per run.
set -euo pipefail
project_root="${0:A:h:h}"
folder="$project_root/Mobile"
command="${1:?Usage: scripts/mobile.sh run | test | package VERSION BUILD DIR | upload IPA}"
shift

# Regenerating rewrites the project, which makes Xcode rebuild everything, so it happens only when the
# project description or the set of files changed.
generate() {
    local tuist stamp
    tuist="$(zsh "$project_root/scripts/install-tuist.sh")"
    stamp="$( { print -r -- "$tuist"; cat "$folder/Project.swift" "$folder/Tuist.swift"
                (cd "$folder" && find Sources Tests Support | sort) } | shasum -a 256)"
    if [[ -d "$folder/NoodleMobile.xcworkspace" && -d "$folder/Derived/Sources" &&
          "$(cat "$folder/Derived/.generated" 2>/dev/null)" == "$stamp" ]]; then
        return
    fi
    (cd "$folder" && "$tuist" generate --no-open >&2)
    print -r -- "$stamp" > "$folder/Derived/.generated"
}

require_key() {
    : "${APPLE_API_KEY_PATH:?Missing App Store Connect key}"
    : "${APPLE_API_KEY_ID:?Missing App Store Connect key ID}"
    : "${APPLE_API_ISSUER_ID:?Missing App Store Connect issuer}"
}

# An iPhone simulator on the newest iOS, preferring one already running.
choose_simulator() {
    simulator="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
phones = [d for runtime, found in sorted(devices.items(), reverse=True) if ".iOS-" in runtime
          for d in found if d["name"].startswith("iPhone")]
print(next((d["udid"] for d in phones if d["state"] == "Booted"), phones[0]["udid"] if phones else ""))')"
    [[ -n "$simulator" ]] || { print -u2 "No iPhone simulator is installed; run: xcodebuild -downloadPlatform iOS"; exit 1; }
}

case "$command" in
    run)
        choose_simulator
        generate
        xcodebuild -workspace "$folder/NoodleMobile.xcworkspace" -scheme NoodleMobile -configuration Debug \
            -derivedDataPath "$folder/Derived" -destination "id=$simulator" build
        xcrun simctl boot "$simulator" 2>/dev/null || true
        # Xcode 27 shows simulators in Device Hub; earlier versions have the Simulator app.
        open "devices://device/open?id=$simulator" 2>/dev/null ||
            open -b com.apple.iphonesimulator --args -CurrentDeviceUDID "$simulator" 2>/dev/null ||
            print -u2 "Neither Device Hub nor the Simulator app is installed, so the simulator runs without a window."
        xcrun simctl install "$simulator" "$folder/Derived/Build/Products/Debug-iphonesimulator/NoodleMobile.app"
        xcrun simctl launch --terminate-running-process "$simulator" com.pdparchitect.noodle.mobile.local
        ;;
    test)
        choose_simulator
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
        # App Store Connect's own checks, so a rejected app fails before its version is tagged.
        xcrun altool --validate-app -f "$output/Noodle-Mobile.ipa" -t ios --api-key "$APPLE_API_KEY_ID" \
            --api-issuer "$APPLE_API_ISSUER_ID" --p8-file-path "$APPLE_API_KEY_PATH"
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
