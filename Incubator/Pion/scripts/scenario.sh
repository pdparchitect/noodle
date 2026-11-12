#!/bin/zsh
# Run by sh or bash, it starts again under zsh, which the rest is written for.
[ -n "${ZSH_VERSION:-}" ] || exec zsh "$0" "$@"
# Opens Pion in a scenario from Scenarios/, in a bundle of its own that cannot reach the network,
# an account or any other Pion's data, and can photograph its window.
set -euo pipefail

pion_root="${0:A:h:h}"
project_root="${pion_root:h:h}"
scenarios="$pion_root/Scenarios"
build_root="$project_root/.build"
app="$build_root/Pion Scenarios.app"
bundle_identifier="com.pdparchitect.pion.scenarios"
entitlements="$build_root/PionScenarios.entitlements"

usage() {
    print -u2 'Usage: Incubator/Pion/scripts/scenario.sh [--no-build] [--shots] [--shadow] [--all] [name|path]'
    print -u2 '  no name     open the picker'
    print -u2 '  --shots     play the timeline and save each capture step to Scenarios/NAME/shots/'
    print -u2 '  --shadow    keep the window shadow in those shots'
    print -u2 '  --all       every scenario in turn'
    print -u2 '  --no-build  derive the bundle from the Pion Dev.app already in .build'
    exit 1
}

build=true shots=false shadow=false all=false selections=()
for argument in "$@"; do
    case "$argument" in
        --no-build) build=false ;;
        --shots) shots=true ;;
        --shadow) shadow=true ;;
        --all) all=true ;;
        -*) usage ;;
        *) selections+=("$argument") ;;
    esac
done
if [[ "$all" == true ]]; then
    [[ ${#selections} == 0 ]] || usage
    for file in "$scenarios"/*/scenario.json(N); do selections+=("${file:h}"); done
fi
[[ ${#selections} -le 1 || "$all" == true ]] || usage
[[ "$shots" == false || ${#selections} -gt 0 ]] || { print -u2 '--shots needs a scenario, or --all.'; exit 1; }

folders=()
for selection in "${selections[@]}"; do
    folder="$selection"
    [[ "$selection" == */* ]] || folder="$scenarios/$selection"
    folder="${folder:A}"
    [[ -f "$folder/scenario.json" ]] || { print -u2 "There is no scenario at $folder."; exit 1; }
    folders+=("$folder")
done

# Scenarios are a development hook, so they start from the development bundle.
source_app="$build_root/Pion Dev.app"
[[ "$build" == false ]] || source_app="$(zsh "$pion_root/scripts/build.sh")"
[[ -d "$source_app" ]] || { print -u2 "Missing $source_app. Run without --no-build first."; exit 1; }

# Anchored, so a shell that merely mentions the path is left alone.
running="^$app/Contents/MacOS/Pion"
pkill -f "$running" 2>/dev/null || true
while pgrep -f "$running" >/dev/null 2>&1; do sleep 0.2; done

[[ "$app" == "$build_root/"*.app ]] || exit 1
rm -rf -- "$app"
ditto "$source_app" "$app"
contents="$app/Contents"
plist="$contents/Info.plist"
# Nothing that runs a harness: no Agent Host and no helpers. Scenario agents are scripted.
rm -rf -- "$contents/XPCServices" "$contents/Helpers"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Pion" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Pion" "$plist"
for key in CFBundleURLTypes NoodleAgentHostService NoodleApplicationIdentifier; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
done
/usr/libexec/PlistBuddy -c "Add :PionScenariosRoot string $scenarios" "$plist"

# The sandbox and read access to the scenarios. No network, account or group entitlement.
rm -f -- "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$entitlements" >/dev/null
readable="com.apple.security.temporary-exception.files.absolute-path.read-only"
/usr/libexec/PlistBuddy -c "Add :$readable array" "$entitlements"
/usr/libexec/PlistBuddy -c "Add :$readable:0 string $scenarios/" "$entitlements"
for folder in "${folders[@]}"; do
    [[ "$folder/" == "$scenarios/"* ]] || /usr/libexec/PlistBuddy -c "Add :$readable:0 string $folder/" "$entitlements"
done

signing_identity="${PION_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    # find-identity -v still lists a revoked certificate, marked CSSMERR_TP_CERT_REVOKED.
    signing_identity="$(security find-identity -v -p codesigning | awk -F '"' '/Apple Development:/ && !/CSSMERR_/ { print $2; exit }')"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
    print -u2 "No Apple Development identity found; using ad-hoc signing."
    codesign --force --deep --timestamp=none --sign - "$app"
fi
codesign --force --options runtime --timestamp=none --entitlements "$entitlements" --sign "$signing_identity" "$app"
codesign --verify --strict "$app"

executable="$contents/MacOS/Pion"
launch_arguments=(-AppleLocale en_US -AppleLanguages '(en)')
if [[ ${#folders} == 0 ]]; then
    open "$app" --args --scenario-picker
    print "Opened $app"
    exit 0
fi

for folder in "${folders[@]}"; do
    if [[ "$shots" == false ]]; then
        # The terminal stays attached: Return does what Scenarios > Next Step does.
        "$executable" --scenario "$folder" "${launch_arguments[@]}"
        continue
    fi
    mkdir -p "$folder/shots"
    taken=0
    # The flag goes last: AppKit reads arguments in pairs. The app waits for an empty line after
    # READY, each SHOT and DONE, so each photograph is taken before the timeline moves on.
    coproc "$executable" --scenario "$folder" "${launch_arguments[@]}" --scenario-shots
    app_pid=$!
    trap 'kill "$app_pid" 2>/dev/null || true' EXIT
    while IFS= read -r -p line; do
        print -r -- "$line"
        case "$line" in
            "SCENARIO SHOT "*)
                fields=(${=line})
                capture_options=(-x)
                [[ "$shadow" == true ]] || capture_options+=(-o)
                # Only Pion's own window. Needs Screen Recording permission for the terminal running this.
                drawn="${fields[6]#drawn=}"
                if screencapture "${capture_options[@]}" -l "${fields[4]#id=}" "$folder/shots/${fields[3]}.png" 2>/dev/null; then
                    taken=$((taken + 1))
                elif [[ "$drawn" != none && -f "$drawn" ]]; then
                    # The screen could not be photographed, as while it is locked: keep the window as Pion drew it.
                    cp "$drawn" "$folder/shots/${fields[3]}.png"
                    taken=$((taken + 1))
                    print -u2 "${fields[3]} is the window as Pion drew it, without its materials: the screen could not be captured."
                else
                    print -u2 "Could not capture ${fields[3]}."
                fi
                print -p ""
                ;;
            "SCENARIO DONE") print -p ""; break ;;
            "SCENARIO READY "*) print -p "" ;;
        esac
    done
    wait "$app_pid" || true
    trap - EXIT
    print "$taken shots in $folder/shots"
done
