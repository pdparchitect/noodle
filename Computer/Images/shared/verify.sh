#!/bin/sh
set -eu
test -x /bin/sh
test -d /workspace
id agent >/dev/null
command -v sudo >/dev/null
test "$(sudo -n -u agent id -u)" = 1000
test "$(sudo -n -u agent sudo -n id -u)" = 0
sudo -n -u agent test -w /workspace
sudo -n -u agent test -w /home/agent
case "${1:-}" in
  shell)
    # Every computer's network is set up from the Shell image with these, Alpine's or a Debian-family base's.
    command -v ip >/dev/null
    command -v udhcpc >/dev/null
    test -x /usr/share/udhcpc/default.script || test -x /etc/udhcpc/default.script
    ;;
  desktop)
    test -x /init
    test -x /usr/local/bin/desktop-resize
    test -x /usr/local/bin/desktop-surface
    test -x /usr/lib/xorg/Xorg
    test -f /usr/lib/xorg/modules/drivers/modesetting_drv.so
    test -f /usr/lib/xorg/modules/input/evdev_drv.so
    for program in openbox picom feh kitty xterm xauth mcookie xrandr xdpyinfo xclip node chromium runuser flock; do command -v "$program" >/dev/null; done
    id -nG agent | grep -qw video
    id -nG agent | grep -qw input
    test -x /usr/local/lib/noodle-chromium-base
    test -x /etc/desktop/session.d/noodle-browser
    node -e 'if (typeof require("/opt/noodle-browser").connect !== "function") process.exit(1)'
    test -x /etc/desktop/session.d/noodle-compositor
    grep -q '^Hidden=true$' /etc/xdg/autostart/picom.desktop
    grep -q '^corner-radius = 12;$' /etc/xdg/picom.conf
    test ! -x /usr/local/bin/desktop-bridge
    test -s /usr/share/backgrounds/desktop-wallpaper.png
    test -s /etc/xdg/kitty/theme.conf
    grep -q '^background #000000$' /etc/xdg/kitty/theme.conf
    grep -q '^rounded = 12$' /etc/xdg/tint2/tint2rc
    grep -q '^window.active.border.color: #000000$' /usr/share/themes/Desktop/openbox-3/themerc
    grep -q 'DESKTOP_WALLPAPER' /etc/xdg/openbox/autostart
    grep -q '/etc/xdg/kitty/theme.conf' /etc/xdg/kitty/kitty.conf
    id agent >/dev/null
    ;;
  *) echo 'Expected shell or desktop' >&2; exit 2 ;;
esac
printf 'PASS: Noodle %s image contract\n' "$1"
