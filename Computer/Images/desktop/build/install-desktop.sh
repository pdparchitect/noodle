#!/bin/bash
set -euo pipefail
arch="${TARGETARCH:-$(dpkg --print-architecture)}"
case "$arch" in
    arm64) cortile_sum="$CORTILE_SHA256_ARM64" ;;
    amd64) cortile_sum="$CORTILE_SHA256_AMD64" ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac
curl -fsSL --retry 3 "https://github.com/leukipp/cortile/releases/download/v${CORTILE_VERSION}/cortile_${CORTILE_VERSION}_linux_${arch}.tar.gz" -o /tmp/cortile.tar.gz
printf '%s  /tmp/cortile.tar.gz\n' "$cortile_sum" | sha256sum -c -
mkdir /tmp/cortile
tar -xzf /tmp/cortile.tar.gz -C /tmp/cortile
install -m 0755 /tmp/cortile/cortile /usr/local/bin/cortile
mkdir -p /usr/share/doc/cortile
# Preserve the release's license alongside the executable.
find /tmp/cortile -iname '*license*' -exec cp {} /usr/share/doc/cortile/ \;
rm -rf /tmp/cortile /tmp/cortile.tar.gz

# Ubuntu Chromium is a Snap launcher. There, use Debian's signed native package on
# ARM64, including security updates, and Google's native Chrome on AMD64. A Debian-family
# base, such as Kali, has a native package of its own.
. /etc/os-release
if [ "$ID" != ubuntu ]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium
elif [ "$arch" = amd64 ]; then
    curl -fsSL --retry 3 https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/browser.deb
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/browser.deb
    rm /tmp/browser.deb
else
    mkdir -p /etc/apt/keyrings
    curl -fsSL --retry 3 https://ftp-master.debian.org/keys/archive-key-12.asc -o /etc/apt/keyrings/debian-archive-key-12.asc
    curl -fsSL --retry 3 https://ftp-master.debian.org/keys/archive-key-12-security.asc >> /etc/apt/keyrings/debian-archive-key-12.asc
    printf '%s\n' \
        'deb [arch=arm64 signed-by=/etc/apt/keyrings/debian-archive-key-12.asc] https://deb.debian.org/debian bookworm main' \
        'deb [arch=arm64 signed-by=/etc/apt/keyrings/debian-archive-key-12.asc] https://security.debian.org/debian-security bookworm-security main' \
        > /etc/apt/sources.list.d/desktop-chromium.list
    printf 'Package: *\nPin: release n=bookworm*\nPin-Priority: 100\n' > /etc/apt/preferences.d/desktop-chromium
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends chromium
fi
rm -rf /var/lib/apt/lists/*
