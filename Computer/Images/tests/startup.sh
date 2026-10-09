#!/bin/bash
# Run as root in a disposable guest without networking or host mounts.
set -euo pipefail
# A VM stopped while /init changed accounts leaves shadow's lock files on the
# kept disk, naming a PID that is alive again on the next boot.
for file in passwd group shadow gshadow; do printf '%s' "$$" > "/etc/$file.lock"; done
# Without the Mac's virtual GPU, the desktop must refuse to start and say why.
if /init >/tmp/noodle-no-gpu.log 2>&1; then
    echo 'Desktop unexpectedly started without a GPU' >&2; exit 1
fi
grep -q 'needs a virtual GPU' /tmp/noodle-no-gpu.log
# A writable layer kept from an older image can carry its /etc/group, without
# the device groups this image gives the desktop user.
groupdel input
gpasswd -d agent video >/dev/null
export DESKTOP_BROWSER_AUTOSTART=0 DESKTOP_TERMINAL_AUTOSTART=0 DESKTOP_TILING_AUTOSTART=0
export DESKTOP_PANEL_AUTOSTART=0 DESKTOP_COMPOSITOR_AUTOSTART=0
# Prove a derived config is loaded and runtime defaults can override it.
cat > /etc/desktop/conf.d/90-fixture.sh <<'CONFIG'
: "${DESKTOP_TITLE:=Fixture desktop}"
export DESKTOP_FIXTURE=loaded
CONFIG
# A drop-in default must replace the base default, while an explicit runtime
# value must survive the same drop-in on the actual session startup.
(unset DESKTOP_TITLE; . /usr/local/lib/desktop-environment; test "$DESKTOP_TITLE" = 'Fixture desktop')
export DESKTOP_TITLE='Runtime fixture'
mkdir -p /usr/local/share/desktop/workspace
printf 'image default\n' > /usr/local/share/desktop/workspace/example.txt
printf 'hidden seed\n' > /usr/local/share/desktop/workspace/.example
printf 'user data\n' > /workspace/example.txt
chown agent:agent /workspace/example.txt
cat > /etc/desktop/startup.d/90-fixture <<'HOOK'
#!/bin/sh
id -u > /run/desktop/startup-user
printf '%s\n' "$DESKTOP_FIXTURE" > /run/desktop/config-fixture
HOOK
cat > /etc/desktop/session.d/90-fixture <<'HOOK'
#!/bin/sh
printf '%s\n' "$(id -u) $DISPLAY $DESKTOP_TITLE $DESKTOP_FIXTURE" > /run/desktop/session-fixture
HOOK
chmod +x /etc/desktop/{startup.d,session.d}/90-fixture
# An image-supplied server configuration replaces the GPU one; the dummy
# driver stands in for the virtual GPU here.
cat > /etc/desktop/xorg.conf <<'CONF'
Section "ServerFlags"
    Option "AutoAddDevices" "false"
EndSection
Section "Device"
    Identifier "dummy"
    Driver "dummy"
    VideoRam 256000
EndSection
Section "Monitor"
    Identifier "monitor"
    HorizSync 5.0-1000.0
    VertRefresh 5.0-200.0
    Modeline "1024x768" 65.00 1024 1048 1184 1344 768 771 777 806 -hsync -vsync
EndSection
Section "Screen"
    Identifier "screen"
    Device "dummy"
    Monitor "monitor"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1024x768"
    EndSubSection
EndSection
CONF
/init >/tmp/noodle-startup.log 2>&1 &
desktop_pid=$!
cleanup() { kill "$desktop_pid" 2>/dev/null || true; wait "$desktop_pid" || true; }
trap cleanup EXIT
for attempt in $(seq 1 80); do
    if [ -s /run/desktop/session-fixture ]; then break; fi
    if ! kill -0 "$desktop_pid" 2>/dev/null || [ "$attempt" = 80 ]; then
        cat /tmp/noodle-startup.log /var/log/desktop/Xorg.log >&2
        exit 1
    fi
    sleep 0.5
done
grep -q '^\[desktop\] ready on :1$' /tmp/noodle-startup.log
test "$(cat /run/desktop/startup-user)" = 0
id -nG agent | tr ' ' '\n' | grep -qx video
id -nG agent | tr ' ' '\n' | grep -qx input
test "$(cat /run/desktop/config-fixture)" = loaded
test "$(cat /run/desktop/session-fixture)" = '1000 :1 Runtime fixture loaded'
test "$(cat /workspace/example.txt)" = 'user data'
test "$(cat /workspace/.example)" = 'hidden seed'
runuser -u agent -- test -w /workspace/.example
test "$(stat -c '%U %a' "$XAUTHORITY")" = 'agent 600'
# The root display server must not leave its caches in the desktop user's home.
test "$(stat -c %U /home/agent/.cache)" = agent
! find /home/agent -user root | grep -q .
pgrep -x Xorg >/dev/null
pgrep -u agent -f desktop-resize >/dev/null
! pgrep -u agent -x chromium >/dev/null
! pgrep -u agent -x kitty >/dev/null
# Nothing on the desktop listens on the network.
test -z "$(ss -Hlnt)"
runuser -u agent -- xdpyinfo | grep 'dimensions:.*1024x768' >/dev/null
kill "$desktop_pid"
wait "$desktop_pid" || true
trap - EXIT
! pgrep -x Xorg >/dev/null
printf 'PASS: X server, non-root session, configuration, hooks, seeds and shutdown\n'
