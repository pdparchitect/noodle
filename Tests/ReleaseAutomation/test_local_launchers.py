"""Launch guards use fake builders and open, never real apps or user data."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LocalLauncherTests(unittest.TestCase):
    def run_fixture(self, produced_id, arguments=()):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts, tools = root / 'scripts', root / 'tools'
            scripts.mkdir()
            tools.mkdir()
            launcher = 'build-and-launch-applet.sh'
            shutil.copyfile(ROOT / 'scripts' / launcher, scripts / launcher)
            app = root / 'Fixture.app'
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as output:
                plistlib.dump({'CFBundleIdentifier': produced_id}, output)
            (scripts / 'build-applet.sh').write_text(
                '#!/bin/zsh\nprint -r -- "$NOODLE_APPLET_DATA_CONTAINER" > "$FIXTURE_BUILD_LOG"\n'
                'print -r -- "$FIXTURE_APP"\n')
            (scripts / 'build-applet.sh').chmod(0o700)
            (tools / 'open').write_text('#!/bin/zsh\nprint -r -- "$*" > "$FIXTURE_OPEN_LOG"\n')
            (tools / 'open').chmod(0o700)
            build_log, open_log = root / 'build.log', root / 'open.log'
            result = subprocess.run(['/bin/zsh', str(scripts / launcher), *arguments],
                env=dict(os.environ, PATH=f'{tools}:/usr/bin:/bin',
                         NOODLE_DATA_CONTAINER='production', NOODLE_APPLET_DATA_CONTAINER='production',
                         FIXTURE_APP=str(app), FIXTURE_BUILD_LOG=str(build_log), FIXTURE_OPEN_LOG=str(open_log)),
                capture_output=True, text=True)
            valid = produced_id == 'com.pdparchitect.noodle.applet.local'
            if arguments:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(build_log.exists())
            else:
                self.assertEqual(build_log.read_text().strip(), 'development')
                self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
            self.assertEqual(open_log.exists(), not arguments and valid)
            if open_log.exists():
                self.assertEqual(open_log.read_text().strip(), str(app))

    def test_launchers_force_local_and_refuse_production_output_or_arguments(self):
        self.run_fixture('com.pdparchitect.noodle.applet.local')
        self.run_fixture('com.pdparchitect.noodle.applet')
        self.run_fixture('com.pdparchitect.noodle.applet.local', ['--production-data'])


if __name__ == '__main__':
    unittest.main()
