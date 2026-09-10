#!/usr/bin/env python3
"""Run real PTY startup checks: python3 welcome.py container|docker shell-image desktop-image."""
import errno
import os
import pty
import select
import subprocess
import sys
import time

runtime, shell_image, desktop_image = sys.argv[1:]
mark = 'N O O D L E'
tagline = 'Your own little workspace.'


def run(image, arguments=(), *, tty=True, entrypoint='/usr/bin/env', environment=(), startup=None):
    command = [runtime, 'run', '--rm', '--network', 'none']
    if tty:
        command += ['-it']
    for value in environment:
        command += ['-e', value]
    if entrypoint:
        command += ['--entrypoint', entrypoint]
    command += [image, *arguments]
    if not tty:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        assert result.returncode == 0, result.stdout.decode(errors='replace')
        return result.stdout.decode(errors='replace')
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output = bytearray()
    deadline = time.monotonic() + 90
    sent = False
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.2)[0]:
                try:
                    part = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not part:
                    break
                output.extend(part)
                if startup and not sent and tagline.encode() in output:
                    os.write(master, startup.encode())
                    sent = True
            if process.poll() is not None:
                break
        else:
            raise AssertionError('Timed out: ' + output.decode(errors='replace'))
        assert process.wait(timeout=5) == 0, output.decode(errors='replace')
        return output.decode(errors='replace')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        os.close(master)


def check(label, output, count=1, colour=None):
    assert output.count(mark) == count, (label, output)
    assert output.count(tagline) == count, (label, output)
    if colour is not None:
        assert ('\x1b[38;2;' in output) == colour, (label, output)
    if count:
        assert "     '--'    '------'" in output, (label, output)
    print('PASS:', label, flush=True)


for image in (shell_image, desktop_image):
    check(image + ': default shell mode', run(image, entrypoint=None, environment=['TERM=xterm-256color'], startup='exit\n'), colour=True)
    check(image + ': native/provider environment', run(image, ['-i', 'PATH=/usr/local/bin:/usr/bin:/bin', 'HOME=/root', 'TERM=xterm-256color', 'ENV=/etc/noodle/interactive-shell.sh', '/bin/sh', '-ic', 'exit']), colour=True)
    check(image + ': login shell prints once', run(image, ['/bin/sh', '-lic', 'exit']))
    check(image + ': repeated hook prints once', run(image, ['/bin/sh', '-ic', '. /etc/noodle/interactive-shell.sh; . /etc/noodle/interactive-shell.sh']))
    check(image + ': nested shell gets its own logo', run(image, ['/bin/sh', '-ic', '/bin/sh -ic exit']), count=2)
    check(image + ': non-interactive stays silent', run(image, ['/bin/sh', '-c', '. /etc/noodle/interactive-shell.sh']), count=0)
    check(image + ': redirected output stays silent', run(image, ['/bin/sh', '-ic', 'exit'], tty=False), count=0)
    check(image + ': NO_COLOR', run(image, ['/bin/sh', '-ic', 'exit'], environment=['TERM=xterm-256color', 'NO_COLOR=1']), colour=False)
    check(image + ': dumb terminal', run(image, ['/bin/sh', '-ic', 'exit'], environment=['TERM=dumb']), colour=False)
    check(image + ': opt out', run(image, ['/bin/sh', '-ic', 'exit'], environment=['NOODLE_BANNER=0']), count=0)
for args in (['/bin/bash', '-ic', 'exit'], ['/bin/bash', '-lic', 'exit'], ['su', '-', 'agent', '-c', '/bin/bash -ic exit']):
    check('Desktop Bash: ' + ' '.join(args), run(desktop_image, args))
