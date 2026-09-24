#!/bin/zsh
# Opens Noodle in a scenario from Scenarios/, in a bundle of its own that cannot reach the network,
# an account or any other Noodle's data, and can photograph or record it.
set -euo pipefail

project_root="${0:A:h:h}"
scenarios="$project_root/Scenarios"
build_root="$project_root/.build"
app="$build_root/Noodle Scenarios.app"
bundle_identifier="com.pdparchitect.noodle.scenarios"
entitlements="$build_root/NoodleScenarios.entitlements"

usage() {
    print -u2 'Usage: scripts/scenario.sh [--no-build] [--debug] [--shots] [--video] [--ratio W:H]'
    print -u2 '                            [--size WxH] [--shadow] [--all] [name|path]'
    print -u2 '  no name     open the picker'
    print -u2 '  --shots     play the timeline and save each capture step to Scenarios/NAME/shots/'
    print -u2 '  --video     play the film and record it to Scenarios/NAME/recordings/NAME.mov'
    print -u2 '  --ratio W:H also write that shape as an .mp4, once per ratio (16:9, 9:16, 1:1, 4:5)'
    print -u2 '  --size WxH  open the main window at that size instead of the scenario'"'"'s own'
    print -u2 '  --silent    leave the sound off the recording'
    print -u2 '  --shadow    keep the window shadow in those shots'
    print -u2 '  --all       every scenario in turn'
    print -u2 '  --no-build  derive the bundle from the Noodle Dev.app already in .build'
    print -u2 '  --debug     build the debug configuration'
    exit 1
}

build=true shots=false record=false shadow=false all=false silent=false
selections=() ratios=() expect_ratio=false size= expect_size=false
for argument in "$@"; do
    if [[ "$expect_ratio" == true ]]; then
        ratios+=("$argument"); expect_ratio=false; continue
    fi
    if [[ "$expect_size" == true ]]; then
        size="$argument"; expect_size=false; continue
    fi
    case "$argument" in
        --no-build) build=false ;;
        --debug) export NOODLE_BUILD_CONFIGURATION=debug ;;
        --shots) shots=true ;;
        --silent) silent=true ;;
        --video) record=true ;;
        --ratio) expect_ratio=true; record=true ;;
        --ratio=*) ratios+=("${argument#--ratio=}"); record=true ;;
        --size) expect_size=true ;;
        --size=*) size="${argument#--size=}" ;;
        --shadow) shadow=true ;;
        --all) all=true ;;
        -*) usage ;;
        *) selections+=("$argument") ;;
    esac
done
[[ "$expect_ratio" == false && "$expect_size" == false ]] || usage
[[ -z "$size" || "$size" == <->x<-> ]] || { print -u2 "$size is not a window size like 1240x860."; exit 1; }
for ratio in "${ratios[@]}"; do
    [[ "$ratio" == <->:<-> ]] || { print -u2 "$ratio is not an aspect ratio like 16:9."; exit 1; }
done
if [[ "$all" == true ]]; then
    [[ ${#selections} == 0 ]] || usage
    for file in "$scenarios"/*/scenario.json(N); do selections+=("${file:h}"); done
fi
[[ ${#selections} -le 1 || "$all" == true ]] || usage
[[ "$shots" == false && "$record" == false || ${#selections} -gt 0 ]] || { print -u2 '--shots and --video need a scenario, or --all.'; exit 1; }

# Anything a scenario names by web address is fetched before the app starts, into one
# cache beside the scenarios: the bundle has no network of its own, and two scenarios
# naming the same thing share a copy. Git ignores the folder.
fetch_media() {
    python3 - "$1" <<'PYTHON'
import hashlib, json, subprocess, sys, urllib.parse
from pathlib import Path

folder = Path(sys.argv[1])
cache = folder.parent / ".cache"
def addresses(node):
    if isinstance(node, dict):
        for value in node.values(): yield from addresses(value)
    elif isinstance(node, list):
        for value in node: yield from addresses(value)
    elif isinstance(node, str) and node.startswith(("http://", "https://")):
        yield node

TYPES = {"video/mp4": ".mp4", "video/quicktime": ".mov", "video/x-m4v": ".m4v",
         "image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic", "image/heif": ".heif"}

wanted = sorted(set(addresses(json.loads((folder / "scenario.json").read_text()))))
for address in wanted:
    stem = hashlib.sha256(address.encode()).hexdigest()[:16]
    if cache.exists() and any(f.name.startswith(stem) for f in cache.iterdir()):
        continue
    cache.mkdir(parents=True, exist_ok=True)
    print(f"Fetching {address}")
    partial = cache / (stem + ".part")
    content_type = subprocess.run(
        ["curl", "--fail", "--location", "--silent", "--show-error", "--max-time", "600",
         "-o", str(partial), "-w", "%{content_type}", address],
        check=True, capture_output=True, text=True).stdout.split(";")[0].strip().lower()
    # The address usually says what it is; when it does not, the server does.
    suffix = Path(urllib.parse.urlparse(address).path).suffix.lower()
    if suffix not in TYPES.values():
        suffix = TYPES.get(content_type, "")
    if not suffix:
        partial.unlink(missing_ok=True)
        raise SystemExit(f"{address} served {content_type or 'nothing'}, which is not a picture or a video")
    partial.rename(cache / (stem + suffix))
PYTHON
}

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
launch_arguments=(-AppleLocale en_US -AppleLanguages '(en)')
[[ -z "$size" ]] || launch_arguments+=(--scenario-size "$size")
if [[ ${#folders} == 0 ]]; then
    # Without this the bundle returns to the scenario it showed last.
    open "$app" --args --scenario-picker
    print "Opened $app"
    exit 0
fi

for folder in "${folders[@]}"; do
    if [[ "$shots" == false && "$record" == false ]]; then
        "$executable" --scenario "$folder" "${launch_arguments[@]}"
        continue
    fi
    fetch_media "$folder"
    [[ "$shots" == false ]] || mkdir -p "$folder/shots"
    [[ "$record" == false ]] || mkdir -p "$folder/recordings"
    taken=0
    recorder= stopped=
    movie="$folder/recordings/${folder:t}.mov"
    cues="$(mktemp)" focus="$(mktemp)"
    # The flag goes last: AppKit reads arguments in pairs, and would take what follows it for its value.
    coproc "$executable" --scenario "$folder" "${launch_arguments[@]}" --scenario-shots
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
        if [[ "$line" == "SCENARIO FOCUS "* ]]; then
            print -r -- "${line#SCENARIO FOCUS }" >> "$focus"
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
            [[ -z "$stopped" || ! -s "$focus" ]] || "$video_tool" zoom "$movie" "$focus" "$stopped"
            [[ "$silent" == true || -z "$stopped" || ! -s "$cues" ]] || "$video_tool" sound "$movie" "$cues" "$stopped"
            # The padding matches the film's own backdrop, so the frame reads as one surface.
            # A picture or video behind the app still pads out to a flat colour.
            background="$(python3 -c 'import json,sys
value = (json.load(open(sys.argv[1])).get("film") or {}).get("background") or "black"
print(value if value in ("black", "white") else "black")' "$folder/scenario.json")"
            for ratio in "${ratios[@]}"; do
                "$video_tool" frame "$movie" "$folder/recordings/${folder:t}-${ratio/:/x}.mp4" "$ratio" "$background"
            done
        else
            print -u2 "Nothing was recorded."
        fi
    fi
    rm -f "$cues" "$focus"
done
