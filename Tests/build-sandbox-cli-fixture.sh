#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
application="$project_root/.build/Sandbox CLI Tests.app"
helpers="$application/Contents/Helpers"

# Build the production CLI targets, without the UI's signing identity, app
# groups, or XPC authentication. These helpers receive the production Seatbelt
# profile from the test process, exactly as they do from the Agent Host.
for product in NoodleMessenger; do
    swift build --disable-sandbox --package-path "$project_root" --product "$product" >&2
done
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
# Start empty: a helper this script no longer builds must not linger from an earlier run.
rm -rf "$helpers"
mkdir -p "$helpers"
cp "$bin_path/NoodleMessenger" "$helpers/messenger"
/usr/bin/codesign --force --sign - --options runtime --timestamp=none "$helpers/messenger" >&2
/usr/bin/codesign --verify --strict "$helpers/messenger" >&2
print "$application"
