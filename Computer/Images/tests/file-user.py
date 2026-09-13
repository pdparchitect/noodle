#!/usr/bin/env python3
"""Exercise the production helper installer after a root-to-agent image update."""
from pathlib import Path
import re
import subprocess
import sys
import uuid

runtime, *images = sys.argv[1:]
source = Path(__file__).resolve().parents[2] / 'Sources/NoodleComputer/GuestFiles.swift'
match = re.search(r'let output = try await run\(arguments: \["/bin/sh", "-c", #"""\n(.*?)\n\s*"""#', source.read_text(), re.S)
assert match, 'Production file helper installer was not found'
installer = match.group(1)
fixture = r'''
set -eu
printf legacy-root-helper > /tmp/.noodle-files-runtime
chmod 700 /tmp/.noodle-files-runtime
path=$(printf '#!/bin/sh\nid -u\n' | sudo -n -u agent /bin/sh -c "$1" noodle-files "$2")
test "$path" = /tmp/.noodle-files-runtime-1000
test "$(stat -c %u "$path")" = 1000
test "$(stat -c %a "$path")" = 700
test "$(sudo -n -u agent "$path")" = 1000
test "$(cat /tmp/.noodle-files-runtime)" = legacy-root-helper
test "$(stat -c %u /tmp/.noodle-files-runtime)" = 0
# Installing again must atomically replace this account's own helper.
next=$(printf updated | sudo -n -u agent /bin/sh -c "$1" noodle-files "$3")
test "$next" = "$path"
test "$(sudo -n -u agent cat "$path")" = updated
'''
for image in images:
    subprocess.run([runtime, 'run', '--rm', '--network', 'none', '--user', 'root',
                    '--entrypoint', '/bin/sh', image, '-c', fixture, 'noodle-file-test',
                    installer, uuid.uuid4().hex, uuid.uuid4().hex], check=True, timeout=90)
    print('PASS:', image, 'agent helper installs beside legacy root helper and replaces its own copy', flush=True)
