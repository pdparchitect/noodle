#!/bin/bash
# Run as root in a disposable guest without networking or host mounts.
set -euo pipefail
if /init >/tmp/noodle-unprepared.log 2>&1; then
    echo 'Unprepared desktop unexpectedly started' >&2; exit 1
fi
if DESKTOP_PASSWORD=short desktop-prepare >/tmp/noodle-invalid.log 2>&1; then
    echo 'Invalid desktop password unexpectedly accepted' >&2; exit 1
fi
export DESKTOP_PASSWORD="$(openssl rand -hex 24)"
export DESKTOP_PORT=7443 DESKTOP_GEOMETRY=1024x768 DESKTOP_FRAME_RATE=20
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
desktop-prepare | base64 -d > /tmp/noodle-certificate.der
openssl x509 -inform DER -in /tmp/noodle-certificate.der -noout >/dev/null
test "$(stat -c %a /run/desktop/health.curl)" = 600
test "$(stat -c %U /run/desktop/health.curl)" = root
/init >/tmp/noodle-startup.log 2>&1 &
desktop_pid=$!
cleanup() { kill "$desktop_pid" 2>/dev/null || true; wait "$desktop_pid" || true; }
trap cleanup EXIT
for attempt in $(seq 1 80); do
    if curl -kfsS -u "agent:$DESKTOP_PASSWORD" https://127.0.0.1:7443/ >/dev/null 2>&1 &&
        [ -s /run/desktop/session-fixture ]; then break; fi
    if ! kill -0 "$desktop_pid" 2>/dev/null || [ "$attempt" = 80 ]; then
        cat /tmp/noodle-startup.log /var/log/desktop/kasmvnc.log >&2
        exit 1
    fi
    sleep 0.5
done
test "$(curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1:7443/)" = 401
test "$(curl -ksS -u agent:invalid -o /dev/null -w '%{http_code}' https://127.0.0.1:7443/)" = 401
if curl -fsS --max-time 2 http://127.0.0.1:7443/ >/dev/null 2>&1; then
    echo 'Desktop accepted plaintext HTTP' >&2; exit 1
fi
python3 - <<'PY_CERT'
import socket, ssl
with socket.create_connection(('127.0.0.1', 7443)) as connection:
    with ssl._create_unverified_context().wrap_socket(connection) as secured:
        with open('/tmp/noodle-served.der', 'wb') as output:
            output.write(secured.getpeercert(binary_form=True))
PY_CERT
cmp /tmp/noodle-certificate.der /tmp/noodle-served.der
test "$(cat /run/desktop/startup-user)" = 0
test "$(cat /run/desktop/config-fixture)" = loaded
test "$(cat /run/desktop/session-fixture)" = '1000 :1 Runtime fixture loaded'
test "$(cat /workspace/example.txt)" = 'user data'
test "$(cat /workspace/.example)" = 'hidden seed'
runuser -u agent -- test -w /workspace/.example
pgrep -u agent -x Xvnc >/dev/null
! pgrep -u root -x Xvnc >/dev/null
! pgrep -u agent -x chromium >/dev/null
! pgrep -u agent -x kitty >/dev/null
! ss -lnt | grep -q ':6902 '
grep -q 'max_frame_rate: 20' /home/agent/.vnc/kasmvnc.yaml
runuser -u agent -- xdpyinfo | grep 'dimensions:.*1024x768' >/dev/null
kill "$desktop_pid"
wait "$desktop_pid"
trap - EXIT
! pgrep -u agent -x Xvnc >/dev/null
printf 'PASS: authenticated HTTPS, certificate, non-root session, configuration, hooks, seeds and shutdown\n'
