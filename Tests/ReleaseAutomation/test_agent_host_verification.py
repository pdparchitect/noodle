"""Verification must drain tool output without hiding rejected bundle metadata."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AgentHostVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.app = root / 'Noodle Local.app'
        host = self.app / 'Contents/XPCServices/NoodleAgentHost.xpc'
        identifier = 'com.example.noodle.local'
        shared = {
            'NoodleSigningTeam': 'ABCDEFGHIJ',
            'NoodleApplicationIdentifier': identifier,
            'NoodleAgentHostService': identifier + '.agent-host',
        }
        for bundle, metadata in [
            (self.app, dict(shared, CFBundleIdentifier=identifier)),
            (host, dict(shared, CFBundleIdentifier=identifier + '.agent-host',
                        XPCService=dict(ServiceType='Application', JoinExistingSession=True))),
        ]:
            contents = bundle / 'Contents'
            contents.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps(metadata))

        tools = root / 'tools'
        tools.mkdir()
        # A match near the start followed by more than a pipe buffer exposes
        # premature grep exits in both successful checks and rejection branches.
        fixture = f'#!{sys.executable}\n' + '''
import os
from pathlib import Path
import sys

args = sys.argv[1:]
component = 'apple' if args[-1].endswith('NoodleAppleAgent') else 'host'
reject = os.environ.get('FIXTURE_REJECT', '')
padding = 'metadata padding\\n' * 32768
if Path(sys.argv[0]).name == 'codesign':
    if '--verify' in args:
        sys.exit(0)
    if '--entitlements' in args:
        if reject == component + '-entitlements':
            print('<key>com.apple.security.network.client</key><true/>' + padding)
    else:
        print('flags=0x10000(runtime)\\nTeamIdentifier=ABCDEFGHIJ\\n' + padding,
              file=sys.stderr)
elif '-L' in args:
    print('/opt/homebrew/lib/unsafe.dylib' if reject == component + '-library'
          else '/usr/lib/libSystem.B.dylib')
    print(padding)
else:
    print('path /tmp/.build/debug' if reject == component + '-rpath'
          else 'path /usr/lib/swift')
    print(padding)
'''
        for name in ['codesign', 'otool']:
            tool = tools / name
            tool.write_text(fixture)
            tool.chmod(0o700)
        helper = self.app / 'Contents/Helpers/NoodleAppleAgent'
        helper.parent.mkdir()
        helper.write_text('#!/bin/sh\nprintf \'{"localModelsSupported":false}\\n\'\n')
        helper.chmod(0o700)
        self.env = dict(os.environ, PATH=f'{tools}:/usr/bin:/bin')

    def verify(self, rejection=''):
        return subprocess.run(
            ['/bin/zsh', str(ROOT / 'scripts/verify-agent-host.sh'), str(self.app)],
            env=dict(self.env, FIXTURE_REJECT=rejection),
            capture_output=True, text=True, timeout=15,
        )

    def test_valid_bundle_with_large_tool_output_passes(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Apple harness signature', result.stdout)

    def test_large_tool_output_preserves_security_rejections(self):
        for component, label in [('host', 'Agent Host'), ('apple', 'Apple harness')]:
            for violation, message in [
                ('entitlements', 'entitlements'),
                ('library', 'mutable external library'),
                ('rpath', 'development-only library search path'),
            ]:
                with self.subTest(component=component, violation=violation):
                    result = self.verify(f'{component}-{violation}')
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn(label, result.stderr)
                    self.assertIn(message, result.stderr)


if __name__ == '__main__':
    unittest.main()
