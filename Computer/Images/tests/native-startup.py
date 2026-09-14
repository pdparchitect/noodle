#!/usr/bin/env python3
"""Exercise the app's actual guest scripts: native-startup.py container|docker image [legacy-image]."""
import re
import subprocess
import sys
import textwrap
from pathlib import Path

source = (Path(__file__).resolve().parents[2] / 'Sources/NoodleComputer/ContainerComputer.swift').read_text()
source = source.split('private func launchDesktop', 1)[1]
prepare = re.search(r'config.arguments = \["/bin/bash", "-c", #"""\n(.*?)\n\s*"""#\]', source, re.S)
launch = re.search(r'config.arguments = \["/bin/bash", "-c", """\n(.*?)\n\s*"""\]', source, re.S)
assert prepare and launch, 'Could not locate the native desktop startup scripts'
script = '''set -euo pipefail
cat > /tmp/native-prepare <<'PREPARE'
''' + textwrap.dedent(prepare[1]) + '''
PREPARE
cat > /tmp/native-launch <<'LAUNCH'
''' + textwrap.dedent(launch[1]) + '''
LAUNCH
export NOODLE_DESKTOP_PASSWORD="$(openssl rand -hex 24)"
export DESKTOP_PORT=6901 DISPLAY=:1
export DESKTOP_BROWSER_AUTOSTART=0 DESKTOP_TERMINAL_AUTOSTART=0
certificate="$(bash /tmp/native-prepare)"
# The app configures its VM hostname as noodle-computer. The CLI uses a random
# hostname, so give that name the same local resolution before testing legacy init.
printf '127.0.0.1 %s\\n' "$(hostname)" >> /etc/hosts
printf '%s' "$certificate" | base64 -d | openssl x509 -inform DER -noout >/dev/null
bash /tmp/native-launch >/tmp/native-desktop.log 2>&1 &
desktop_pid=$!
trap 'kill "$desktop_pid" 2>/dev/null || true' EXIT
for attempt in $(seq 1 80); do
    if curl -kfsS -u "agent:$NOODLE_DESKTOP_PASSWORD" https://127.0.0.1:6901/ >/dev/null 2>&1; then break; fi
    if ! kill -0 "$desktop_pid" 2>/dev/null || [ "$attempt" = 80 ]; then
        cat /tmp/native-desktop.log >&2
        for log in /var/log/desktop/kasmvnc.log /var/log/launcher-desktop/kasmvnc.log; do
            [ ! -f "$log" ] || cat "$log" >&2
        done
        exit 1
    fi
    sleep 0.5
done
test "$(curl -ksS -o /dev/null -w '%{http_code}' https://127.0.0.1:6901/)" = 401
pgrep -u agent -x Xvnc >/dev/null
printf 'PASS: native app preparation, certificate and authenticated desktop startup\\n'
'''
for image in sys.argv[2:]:
    result = subprocess.run([sys.argv[1], 'run', '--rm', '-i', '--user', 'root',
                             '--network', 'none', '--memory', '4g', '--entrypoint', '/bin/bash', image],
                            input=script, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=120)
    print(image + ':\n' + result.stdout, flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
