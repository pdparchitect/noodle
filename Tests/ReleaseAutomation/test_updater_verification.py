"""Exercise updater verification with local bundles and deterministic tool responses."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class UpdaterVerificationTests(unittest.TestCase):
    def verify(self, bundle, channel, actual_channel=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / 'Fixture.app'
            contents = app / 'Contents'
            contents.mkdir(parents=True)
            feed = lambda value: ('https://github.com/pdparchitect/noodle/releases/latest/download/appcast.xml'
                                  if value == 'noodle' else
                                  f'https://github.com/pdparchitect/noodle/releases/download/{value}-latest/appcast.xml')
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'Fixture',
                'SUEnableInstallerLauncherService': True, 'SURequireSignedFeed': True,
                'SUVerifyUpdateBeforeExtraction': True, 'NoodleUpdatesEnabled': True,
                'SUPublicEDKey': '1ZT5NrPiDPaQ54iHGSI1a9JIn6kTrmjQvzZRBA9f/sk=',
                'SUFeedURL': feed(actual_channel or channel),
            }))
            resources = contents / 'Resources'
            resources.mkdir()
            (resources / 'Sparkle-LICENSE.txt').write_text('Fixture licence')
            tools = root / 'tools'
            tools.mkdir()
            fixture = f'#!{sys.executable}\n' + '''
import os
from pathlib import Path
import sys
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'codesign':
    if '--verify' in args:
        sys.exit(0)
    if '--entitlements' in args:
        if args[-1] == os.environ['FIXTURE_APP']:
            bundle = os.environ['FIXTURE_BUNDLE']
            print('<key>com.apple.security.app-sandbox</key><true/>'
                  '<key>com.apple.security.temporary-exception.mach-lookup.global-name</key>'
                  f'<array><string>{bundle}-spks</string><string>{bundle}-spki</string></array>')
    else:
        print('TeamIdentifier=ABCDEFGHIJ\\nflags=0x10000(runtime)', file=sys.stderr)
elif '-L' in args:
    print('@rpath/Sparkle.framework/Versions/B/Sparkle')
else:
    print('cmd LC_RPATH\\npath @executable_path/../Frameworks (offset 12)')
'''
            for name in ['codesign', 'otool']:
                tool = tools / name
                tool.write_text(fixture)
                tool.chmod(0o700)
            return subprocess.run(['/bin/zsh', str(ROOT / 'scripts/verify-updater.sh'), str(app)],
                                  env=dict(os.environ, PATH=f'{tools}:/usr/bin:/bin',
                                           FIXTURE_APP=str(app), FIXTURE_BUNDLE=bundle,
                                           NOODLE_REQUIRE_DEVELOPER_ID='1'),
                                  capture_output=True, text=True, timeout=15)

    def test_rook_production_and_development_use_their_own_feed(self):
        for bundle in ['com.pdparchitect.rook', 'com.pdparchitect.rook.local']:
            with self.subTest(bundle=bundle):
                result = self.verify(bundle, 'rook')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('Updater signatures', result.stdout)

    def test_other_apps_keep_their_existing_feeds(self):
        for product in ['noodle', 'pion', 'computer', 'applet', 'browser', 'hub']:
            bundle = f'com.pdparchitect.{product}' if product in ['noodle', 'pion'] else f'com.pdparchitect.noodle.{product}'
            with self.subTest(product=product):
                result = self.verify(bundle, product)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rook_rejects_another_apps_feed(self):
        for wrong in ['noodle', 'pion']:
            with self.subTest(channel=wrong):
                result = self.verify('com.pdparchitect.rook', 'rook', actual_channel=wrong)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Unexpected update feed for com.pdparchitect.rook', result.stderr)
                self.assertIn('rook-latest/appcast.xml', result.stderr)


if __name__ == '__main__':
    unittest.main()
