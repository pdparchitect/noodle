#!/bin/zsh
# Notarizes one file and returns once Apple accepts it. notarytool --wait loses the submission to a
# single dropped connection and waits for as long as Apple's queue does, so this polls the submission
# by ID, rides out network errors and gives up at NOODLE_NOTARY_TIMEOUT seconds (30 minutes).
set -euo pipefail
zmodload zsh/datetime
file="${1:?Usage: scripts/notarize.sh FILE}"
: "${APPLE_API_KEY_PATH:?Set the notarization key path}"
: "${APPLE_API_KEY_ID:?Set the notarization key ID}"
: "${APPLE_API_ISSUER_ID:?Set the notarization issuer ID}"
timeout="${NOODLE_NOTARY_TIMEOUT:-1800}"
poll="${NOODLE_NOTARY_POLL:-30}"
credentials=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
field() { python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"; }

submission=""
for attempt in 1 2 3; do
    if output="$(xcrun notarytool submit "$file" "${credentials[@]}" --output-format json)"; then
        submission="$(print -r -- "$output" | field id)"
        [[ -n "$submission" ]] && break
    fi
    print -u2 "Notarization upload attempt $attempt failed."
    sleep "$poll"
done
[[ -n "$submission" ]] || { print -u2 "Could not upload ${file:t} for notarization."; exit 1; }
print -u2 "Notarization submission $submission for ${file:t}."

deadline=$(( EPOCHSECONDS + timeout ))
while true; do
    state=""
    if output="$(xcrun notarytool info "$submission" "${credentials[@]}" --output-format json)"; then
        state="$(print -r -- "$output" | field status)"
    fi
    case "$state" in
        Accepted) exit 0 ;;
        ""|"In Progress") ;;
        *)
            print -u2 "Notarization of ${file:t} ended as $state."
            xcrun notarytool log "$submission" "${credentials[@]}" >&2 || true
            exit 1
            ;;
    esac
    if (( EPOCHSECONDS >= deadline )); then
        print -u2 "Apple has not finished notarizing ${file:t} after $timeout seconds; submission $submission."
        exit 1
    fi
    sleep "$poll"
done
