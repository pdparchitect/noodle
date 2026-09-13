#!/usr/bin/env python3
"""Exercise guest shell selection and editing through real Linux PTYs.

Usage: python3 Computer/Tests/GuestShellTests.py IMAGE [IMAGE ...]
Requires Apple's container CLI. Each test uses a disposable container without
networking or host mounts. Images must already be available locally.
"""

import os
from pathlib import Path
import pty
import re
import select
import subprocess
import sys
import time
import uuid


def shell_command():
    # Read the raw Swift string used by both native and provider terminals so
    # this integration test executes the actual launcher rather than a copy.
    source = Path(__file__).resolve().parents[1] / "Sources/NoodleComputer/GuestShell.swift"
    match = re.search(r'static let command = #"""\n(.*?)\n\s*"""#', source.read_text(), re.S)
    if not match:
        raise AssertionError("Could not read the guest shell launcher")
    return match.group(1)


def check(image):
    name = "noodle-shell-test-" + uuid.uuid4().hex
    master, slave = pty.openpty()
    arguments = ["container", "run", "--rm", "--name", name, "--network", "none",
                 "--interactive", "--tty", "--entrypoint", "/bin/sh",
                 "--env", "HOME=/root", "--env", "TERM=xterm-256color",
                 "--env", "ENV=/etc/noodle/interactive-shell.sh", image, "-c",
                 "printf '\\n__BOOT__\\n'\n" + shell_command()]
    process = subprocess.Popen(arguments, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    pending = bytearray()

    def expect(pattern, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            match = re.search(pattern, pending)
            if match:
                result = match.group(0)
                del pending[:match.end()]
                return result.decode(errors="replace")
            if select.select([master], [], [], 0.1)[0]:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    break
                if not data:
                    break
                pending.extend(data)
        raise AssertionError(f"Missing {pattern!r}: {pending.decode(errors='replace')[-2000:]}")

    def send(text):
        os.write(master, text.encode())

    try:
        expect(rb"__BOOT__", timeout=30)
        send("printf '\\n__SHELL_%s__\\n' \"$SHELL\"\r")
        selected = expect(rb"__SHELL_/[^\r\n]*__")
        # The Desktop profile rewrites PS1 on every prompt. Use a deterministic
        # prompt so input is sent only after the previous command has finished.
        send("unset PROMPT_COMMAND; PS1=$(printf '__PROMPT_%s__ ' READY)\r")
        expect(rb"__PROMPT_READY__")
        # Verify the passwd shell is selected when it is executable.
        send("while IFS=: read -r n p u g c h s; do [ \"$u\" = 0 ] || continue; "
             "printf '\\n__ACCOUNT_%s__\\n' \"$s\"; break; done < /etc/passwd\r")
        account = expect(rb"__ACCOUNT_/[^\r\n]*__")
        assert selected.removeprefix("__SHELL_") == account.removeprefix("__ACCOUNT_"), (selected, account)
        expect(rb"__PROMPT_READY__")

        send("printf '\\n__HISTORY_%s__\\n' OK\r")
        expect(rb"__HISTORY_OK__")
        expect(rb"__PROMPT_READY__")
        send("\x1b[A\r")
        expect(rb"__HISTORY_OK__")
        expect(rb"__PROMPT_READY__")

        # Kill a partially typed line using Ctrl-A/Ctrl-K, then enter a new one.
        send("this command must never run\x01\x0bprintf '\\n__EDIT_%s__\\n' OK\r")
        expect(rb"__EDIT_OK__")
        expect(rb"__PROMPT_READY__")

        # Use the exact Option-left sequence emitted by the native terminal.
        send("printf '\\n__WORD_%s__\\n' ONE TWO\x1b[1;3DX\r")
        expect(rb"__WORD_XTWO__")
        expect(rb"__PROMPT_READY__")

        send("printf '\\n__TAB_%s__\\n' /work\t\r")
        expect(rb"__TAB_/workspace/?__")
        expect(rb"__PROMPT_READY__")

        send("sleep 30\r")
        time.sleep(0.2)
        send("\x03")
        send("printf '\\n__INTERRUPT_%s__\\n' OK\r")
        expect(rb"__INTERRUPT_OK__")
        expect(rb"__PROMPT_READY__")
        send("\x04")
        deadline = time.monotonic() + 15
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                try:
                    pending.extend(os.read(master, 65536))
                except OSError:
                    break
        assert process.poll() is not None, f"Ctrl-D did not exit: {pending.decode(errors='replace')[-1000:]}"
        assert process.returncode == 0, process.returncode
        print(f"PASS {image}: {selected}, history, line editing, Option-left, Tab, Ctrl-C, Ctrl-D", flush=True)
    finally:
        os.close(master)
        if process.poll() is None:
            subprocess.run(["container", "stop", name], capture_output=True, timeout=20)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        # --rm normally removes it; this only addresses our own failed fixture.
        subprocess.run(["container", "delete", name], capture_output=True, timeout=20)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    for image in sys.argv[1:]:
        check(image)
