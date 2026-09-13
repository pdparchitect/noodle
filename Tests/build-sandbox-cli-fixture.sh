#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
application="$project_root/.build/Sandbox CLI Tests.app"
helpers="$application/Contents/Helpers"

# Build the production CLI targets, without the UI's signing identity, app
# groups, or XPC authentication. These helpers receive the production Seatbelt
# profile from the test process, exactly as they do from the Agent Host.
for product in NoodleMessenger NoodleMCPCLI NoodleComputerCLI; do
    swift build --disable-sandbox --package-path "$project_root" --product "$product" >&2
done
bin_path="$(swift build --disable-sandbox --package-path "$project_root" --show-bin-path)"
swift build --disable-sandbox --package-path "$project_root/Applet" \
    --scratch-path "$project_root/.build/applet" --product noodlet >&2
applet_bin="$(swift build --disable-sandbox --package-path "$project_root/Applet" \
    --scratch-path "$project_root/.build/applet" --show-bin-path)"
mkdir -p "$helpers"
cp "$bin_path/NoodleMessenger" "$helpers/messenger"
cp "$bin_path/NoodleMCPCLI" "$helpers/mcpshim"
cp "$bin_path/NoodleComputerCLI" "$helpers/computer"
cp "$applet_bin/noodlet" "$helpers/noodlet"
for helper in messenger mcpshim computer noodlet; do
    /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$helpers/$helper" >&2
    /usr/bin/codesign --verify --strict "$helpers/$helper" >&2
done
print "$application"
