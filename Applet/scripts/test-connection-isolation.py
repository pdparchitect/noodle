#!/usr/bin/env python3
"""Signed headless peers, temporary sockets only. No apps or UI are launched."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    identities = subprocess.check_output(['security', 'find-identity', '-v', '-p', 'codesigning'], text=True)
    match = re.search(r'"((?:Developer ID Application|Apple Development):[^\"]+)"', identities)
    if not match:
        raise RuntimeError('A signing identity is required')
    identity = os.environ.get('NOODLE_SIGNING_IDENTITY', match.group(1))
    # Short paths are required by sockaddr_un. All artifacts are removed on exit.
    with tempfile.TemporaryDirectory(prefix='applet-peers-', dir='/tmp') as temporary:
        root = Path(temporary)
        executable = root / 'probe'
        run('xcrun', 'swiftc', '-parse-as-library', *sorted((ROOT / 'Applet/Protocol/Sources/AppletBridge').glob('*.swift')),
            ROOT / 'Applet/Tests/ConnectionIsolation.swift', '-o', executable)
        peers = {}
        for channel, suffix in [('production', ''), ('development', '.local')]:
            for role, identifier in [('server', 'com.pdparchitect.noodle.applet' + suffix),
                                     ('broker', 'com.pdparchitect.noodle' + suffix),
                                     ('cli', 'com.pdparchitect.noodle.applet' + suffix + '.cli')]:
                path = root / (channel + '-' + role)
                shutil.copy2(executable, path)
                run('codesign', '--force', '--options', 'runtime', '--timestamp=none', '--identifier', identifier, '--sign', identity, path,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                run('codesign', '--verify', '--strict', path)
                assert subprocess.check_output([str(path), 'identity'], text=True).strip() == channel
                peers[channel, role] = path
        signature = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(peers['production', 'server'])], stderr=subprocess.STDOUT, text=True)
        team = re.search(r'^TeamIdentifier=(.+)$', signature, re.M).group(1)
        for channel, suffix in [('production', ''), ('development', '.local')]:
            socket = root / (channel + '.sock')
            server = subprocess.Popen([str(peers[channel, 'server']), 'server', str(socket), team])
            try:
                for _ in range(100):
                    if socket.exists():
                        break
                    if server.poll() is not None:
                        raise RuntimeError('Test peer exited before listening')
                    time.sleep(.05)
                assert socket.exists(), 'Test socket did not become ready'
                other = 'development' if channel == 'production' else 'production'
                for role in ['broker', 'cli']:
                    run(peers[channel, role], 'client', socket, team, stdout=subprocess.DEVNULL)
                    for provider_override in [[], ['com.pdparchitect.noodle.applet' + suffix]]:
                        result = subprocess.run([str(peers[other, role]), 'client', str(socket), team, *provider_override], capture_output=True, text=True)
                        assert result.returncode != 0, 'Cross-environment connection was accepted'
                        assert 'not an authorized' in result.stderr or 'Untrusted' in result.stderr, result.stderr
                print(f'PASS: {channel} accepts its broker and CLI; both cross-environment authentication checks reject foreign peers')
            finally:
                server.terminate()
                server.wait(timeout=5)


if __name__ == '__main__':
    main()
