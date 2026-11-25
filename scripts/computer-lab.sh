#!/bin/zsh
# Development only: builds computer-lab, signs it so it may run virtual machines, and runs it with the
# pinned runtime kernel. Images, disks, boot logs and the lab's socket live in .build/computer-lab.
#   scripts/computer-lab.sh serve Computer/Prototypes/NetworkLab/gateway.json   (stays running; down stops it)
#   scripts/computer-lab.sh exec client -- nmap -sS 10.66.0.1
#   scripts/computer-lab.sh plug client 0 none
#   scripts/computer-lab.sh down
set -euo pipefail
root="${0:A:h:h}"
state="$root/.build/computer-lab"
mkdir -p "$state"
binary="$(swift build --package-path "$root/Computer" --show-bin-path)/ComputerLab"
if [[ "${1:-}" == serve ]]; then
    zsh "$root/scripts/build-priority.sh" swift build --package-path "$root/Computer" --product ComputerLab >&2
    cat > "$state/lab.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
    codesign --force --sign - --entitlements "$state/lab.entitlements" "$binary" >&2
fi
export COMPUTER_LAB_STATE="$state" COMPUTER_LAB_KERNEL="$root/Computer/Resources/Runtime/vmlinux-arm64"
exec "$binary" "$@"
