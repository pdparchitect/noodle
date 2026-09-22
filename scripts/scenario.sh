#!/bin/zsh
# Opens Noodle in a scenario from Scenarios/, in a bundle of its own that cannot reach the network,
# an account or any other Noodle's data, and can photograph or record it. See Scenarios/README.md.
set -euo pipefail

project_root="${0:A:h:h}"
scenarios="$project_root/Scenarios"
build_root="$project_root/.build"
app="$build_root/Noodle Scenarios.app"
bundle_identifier="com.pdparchitect.noodle.scenarios"
entitlements="$build_root/NoodleScenarios.entitlements"

usage() {
    print -u2 'Usage: scripts/scenario.sh [--no-build] [--debug] [--shots] [--video] [--ratio W:H]'
    print -u2 '                            [--shadow] [--all] [name|path]'
    print -u2 '  no name     open the picker'
    print -u2 '  --shots     play the timeline and save each capture step to Scenarios/NAME/shots/'
    print -u2 '  --video     play the film and record it to Scenarios/NAME/recordings/NAME.mov'
    print -u2 '  --ratio W:H also write that shape as an .mp4, once per ratio (16:9, 9:16, 1:1, 4:5)'
    print -u2 '  --shadow    keep the window shadow in those shots'
    print -u2 '  --all       every scenario in turn'
    print -u2 '  --no-build  derive the bundle from the Noodle Dev.app already in .build'
    print -u2 '  --debug     build the debug configuration'
    exit 1
}

build=true shots=false record=false shadow=false all=false
selections=() ratios=() expect_ratio=false
for argument in "$@"; do
    if [[ "$expect_ratio" == true ]]; then
        ratios+=("$argument"); expect_ratio=false; continue
    fi
    case "$argument" in
        --no-build) build=false ;;
        --debug) export NOODLE_BUILD_CONFIGURATION=debug ;;
        --shots) shots=true ;;
        --video) record=true ;;
        --ratio) expect_ratio=true; record=true ;;
        --ratio=*) ratios+=("${argument#--ratio=}"); record=true ;;
        --shadow) shadow=true ;;
        --all) all=true ;;
        -*) usage ;;
        *) selections+=("$argument") ;;
    esac
done
[[ "$expect_ratio" == false ]] || usage
for ratio in "${ratios[@]}"; do
    [[ "$ratio" == <->:<-> ]] || { print -u2 "$ratio is not an aspect ratio like 16:9."; exit 1; }
done
if [[ "$all" == true ]]; then
    [[ ${#selections} == 0 ]] || usage
    for file in "$scenarios"/*/scenario.json(N); do selections+=("${file:h}"); done
fi
[[ ${#selections} -le 1 || "$all" == true ]] || usage
[[ "$shots" == false && "$record" == false || ${#selections} -gt 0 ]] || { print -u2 '--shots and --video need a scenario, or --all.'; exit 1; }

folders=()
for selection in "${selections[@]}"; do
    folder="$selection"
    [[ "$selection" == */* ]] || folder="$scenarios/$selection"
    folder="${folder:A}"
    [[ -f "$folder/scenario.json" ]] || { print -u2 "There is no scenario at $folder."; exit 1; }
    folders+=("$folder")
done

# Scenarios are a development hook, so they start from the development bundle.
source_app="$build_root/Noodle Dev.app"
if [[ "$build" == true ]]; then
    source_app="$(NOODLE_DATA_CONTAINER=development zsh "$project_root/scripts/build-app.sh")"
fi
[[ -d "$source_app" ]] || { print -u2 "Missing $source_app. Run without --no-build first."; exit 1; }
# Count, so grep reads to the end: leaving early would break the pipe under pipefail.
if [[ "$(strings -a "$source_app/Contents/MacOS/Noodle" | grep -c 'noodle\.development-hooks\.enabled' || true)" == 0 ]]; then
    print -u2 "$source_app was built without development hooks. Run without --no-build."
    exit 1
fi

# Anchored, so a shell that merely mentions the path is left alone.
running="^$app/Contents/MacOS/Noodle"
pkill -f "$running" 2>/dev/null || true
while pgrep -f "$running" >/dev/null 2>&1; do sleep 0.2; done

rm -rf "$app"
ditto "$source_app" "$app"
contents="$app/Contents"
plist="$contents/Info.plist"
# Nothing that reaches outside the app: no share or tool extensions, no Agent Host, no shortcuts,
# and none of the URL schemes, services or groups the development bundle registers.
rm -rf "$contents/PlugIns" "$contents/Extensions" "$contents/XPCServices/NoodleAgentHost.xpc" "$contents/Resources/Metadata.appintents"
rmdir "$contents/XPCServices" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Noodle" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Noodle" "$plist"
for key in CFBundleURLTypes NSServices NoodleSharedGroup NoodleBrowserGroup NoodleAppletGroup NoodleComputerGroup; do
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
done
/usr/libexec/PlistBuddy -c "Add :NoodleScenariosRoot string $scenarios" "$plist"

# The sandbox, and read access to the scenario folders. No network, account, group or helper entitlement.
rm -f "$entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$entitlements" >/dev/null
/usr/libexec/PlistBuddy -c "Add :com.apple.security.files.user-selected.read-only bool true" "$entitlements"
readable="com.apple.security.temporary-exception.files.absolute-path.read-only"
/usr/libexec/PlistBuddy -c "Add :$readable array" "$entitlements"
/usr/libexec/PlistBuddy -c "Add :$readable:0 string $scenarios/" "$entitlements"
for folder in "${folders[@]}"; do
    if [[ "$folder/" != "$scenarios/"* ]]; then
        /usr/libexec/PlistBuddy -c "Add :$readable:0 string $folder/" "$entitlements"
    fi
done

signing_identity="${NOODLE_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning \
        | awk -F '"' '/Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
    print -u2 "No Apple Development identity found; using ad-hoc signing."
    # Code signed by a team does not load into an ad-hoc host, so everything inside is signed the same way.
    codesign --force --deep --timestamp=none --sign - "$app"
fi
codesign --force --options runtime --timestamp=none --entitlements "$entitlements" --sign "$signing_identity" "$app"
codesign --verify --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == "$bundle_identifier" ]]

video_tool="$build_root/scenario-video"
if [[ "$record" == true ]]; then
    if [[ ! -x "$video_tool" || "$project_root/scripts/scenario-video.swift" -nt "$video_tool" ]]; then
        zsh "$project_root/scripts/swift-apple.sh" build --product Noodle >/dev/null 2>&1 || true
        xcrun swiftc -O "$project_root/scripts/scenario-video.swift" -o "$video_tool"
    fi
fi

executable="$contents/MacOS/Noodle"
# The scenario argument keeps the terminal attached: Return does what Scenarios > Next Step does.
locale=(-AppleLocale en_US -AppleLanguages '(en)')
if [[ ${#folders} == 0 ]]; then
    # Without this the bundle returns to the scenario it showed last.
    open "$app" --args --scenario-picker
    print "Opened $app"
    exit 0
fi

for folder in "${folders[@]}"; do
    if [[ "$shots" == false && "$record" == false ]]; then
        "$executable" --scenario "$folder" "${locale[@]}"
        continue
    fi
    [[ "$shots" == false ]] || mkdir -p "$folder/shots"
    [[ "$record" == false ]] || mkdir -p "$folder/recordings"
    taken=0
    recorder= stopped=
    movie="$folder/recordings/${folder:t}.mov"
    cues="$(mktemp)"
    # The flag goes last: AppKit reads arguments in pairs, and would take what follows it for its value.
    coproc "$executable" --scenario "$folder" "${locale[@]}" --scenario-shots
    app_pid=$!
    trap 'kill "$app_pid" 2>/dev/null || true; [[ -z "$recorder" ]] || kill -INT "$recorder" 2>/dev/null || true' EXIT
    # The app waits for an empty line after READY, each SHOT and DONE, so the recorder is rolling
    # before the timeline plays and has stopped before the window closes.
    while IFS= read -r -p line; do
        # The app reports every sound it makes, with the time, for the track laid down below.
        if [[ "$line" == "SCENARIO SOUND "* ]]; then
            print -r -- "${line#SCENARIO SOUND }" >> "$cues"
            continue
        fi
        print -r -- "$line"
        case "$line" in
            "SCENARIO READY "*)
                if [[ "$record" == true ]]; then
                    fields=(${=line})
                    region="${fields[3]#rect=}"
                    if [[ "$region" == none ]]; then
                        print -u2 "There is no main window to record."
                    else
                        rm -f "$movie"
                        # Needs Screen Recording permission for the terminal running this script.
                        screencapture -v -R "$region" "$movie" </dev/null &
                        recorder=$!
                        # Long enough for the recorder to be running before the film starts.
                        sleep 0.8
                    fi
                fi
                print -p ""
                ;;
            "SCENARIO SHOT "*)
                if [[ "$shots" == true ]]; then
                    fields=(${=line})
                    capture_options=(-x)
                    [[ "$shadow" == true ]] || capture_options+=(-o)
                    # Needs Screen Recording permission for the terminal running this script.
                    if screencapture "${capture_options[@]}" -l "${fields[4]#id=}" "$folder/shots/${fields[3]}.png"; then
                        taken=$((taken + 1))
                    else
                        print -u2 "Could not capture ${fields[3]}."
                    fi
                fi
                print -p ""
                ;;
            "SCENARIO DONE")
                if [[ -n "$recorder" ]]; then
                    # Let the last change settle on screen before the recording ends.
                    sleep 1
                    stopped="$(python3 -c 'import time; print(time.time())')"
                    kill -INT "$recorder" 2>/dev/null || true
                    wait "$recorder" 2>/dev/null || true
                    recorder=
                fi
                print -p ""
                break
                ;;
        esac
    done
    wait "$app_pid" || true
    trap - EXIT
    [[ "$shots" == false ]] || print "$taken shots in $folder/shots"
    if [[ "$record" == true ]]; then
        if [[ -s "$movie" ]]; then
            print "Recorded $movie"
            [[ ! -s "$cues" || -z "$stopped" ]] || "$video_tool" sound "$movie" "$cues" "$stopped"
            # The padding matches the film's own backdrop, so the frame reads as one surface.
            background="$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("film") or {}).get("background") or "black")' "$folder/scenario.json")"
            for ratio in "${ratios[@]}"; do
                "$video_tool" frame "$movie" "$folder/recordings/${folder:t}-${ratio/:/x}.mp4" "$ratio" "$background"
            done
        else
            print -u2 "Nothing was recorded."
        fi
    fi
    rm -f "$cues"
done
