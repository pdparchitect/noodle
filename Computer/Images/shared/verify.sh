#!/bin/sh
set -eu
test -x /bin/sh
test -d /workspace
case "${1:-}" in
  shell)
    test -f /etc/alpine-release
    # Network.ext4 currently depends on these Alpine applets.
    command -v ip >/dev/null
    command -v udhcpc >/dev/null
    ;;
  desktop)
    test -x /init
    for program in Xvnc openbox feh kitty xterm openssl kasmvncpasswd; do command -v "$program" >/dev/null; done
    test ! -x /usr/local/bin/desktop-bridge
    test -s /usr/share/backgrounds/desktop-wallpaper.svg
    test -s /etc/xdg/kitty/theme.conf
    grep -q 'DESKTOP_WALLPAPER' /etc/xdg/openbox/autostart
    grep -q '/etc/xdg/kitty/theme.conf' /etc/xdg/openbox/autostart
    id agent >/dev/null
    ;;
  *) echo 'Expected shell or desktop' >&2; exit 2 ;;
esac
printf 'PASS: Noodle %s image contract\n' "$1"
