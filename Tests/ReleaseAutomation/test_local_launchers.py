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
    def run_fixture(self, launcher, builder, expected_id, produced_id, arguments=()):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts, tools = root / 'scripts', root / 'tools'
            scripts.mkdir()
            tools.mkdir()
            shutil.copyfile(ROOT / 'scripts' / launcher, scripts / launcher)
            app = root / 'Fixture.app'
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as output:
                plistlib.dump({'CFBundleIdentifier': produced_id}, output)
            (scripts / builder).write_text('''#!/bin/zsh
print -r -- "$NOODLE_DATA_CONTAINER/$NOODLE_COMPUTER_DATA_CONTAINER/${NOODLE_COMPUTER_TEST_BUILD:-0}/$NOODLE_APPLET_DATA_CONTAINER/$NOODLE_BROWSER_DATA_CONTAINER/$NOODLE_HUB_DATA_CONTAINER/$*" > "$FIXTURE_BUILD_LOG"
print -r -- "$FIXTURE_APP"
''')
            (scripts / builder).chmod(0o700)
            (scripts / 'install-computer-dev.py').write_text('''import os, pathlib, sys
pathlib.Path(os.environ['FIXTURE_INSTALL_LOG']).write_text(sys.argv[1])
print(os.environ['FIXTURE_INSTALLED_APP'])
''')
            (tools / 'open').write_text('#!/bin/zsh\nprint -r -- "$*" > "$FIXTURE_OPEN_LOG"\n')
            (tools / 'open').chmod(0o700)
            build_log, open_log, install_log = root / 'build.log', root / 'open.log', root / 'install.log'
            installed = root / 'Applications/Fixture.app'
            result = subprocess.run(['/bin/zsh', str(scripts / launcher), *arguments],
                env=dict(os.environ, PATH=f'{tools}:/usr/bin:/bin',
                         NOODLE_DATA_CONTAINER='production', NOODLE_COMPUTER_DATA_CONTAINER='production',
                         NOODLE_COMPUTER_TEST_BUILD='1', NOODLE_APPLET_DATA_CONTAINER='production',
                         NOODLE_BROWSER_DATA_CONTAINER='production',
                         NOODLE_HUB_DATA_CONTAINER='production', FIXTURE_APP=str(app),
                         FIXTURE_INSTALLED_APP=str(installed), FIXTURE_INSTALL_LOG=str(install_log),
                         FIXTURE_BUILD_LOG=str(build_log), FIXTURE_OPEN_LOG=str(open_log)),
                capture_output=True, text=True)
            if arguments:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(build_log.exists())
            else:
                fields = build_log.read_text().strip().split('/')
                if launcher == 'build-and-launch.sh':
                    self.assertEqual(fields[0], 'development')
                elif launcher == 'build-and-launch-computer.sh':
                    self.assertEqual(fields[1:3], ['development', '0'])
                else:
                    # Xcode-built apps share one build script, told which app to build.
                    name, container = {'build-and-launch-applet.sh': ('Applet', 3), 'build-and-launch-browser.sh': ('Browser', 4),
                                      'build-and-launch-hub.sh': ('Hub', 5)}[launcher]
                    self.assertEqual((fields[container], fields[6]), ('development', name))
                self.assertEqual(result.returncode, 0 if expected_id == produced_id else 1, result.stderr)
            self.assertEqual(open_log.exists(), not arguments and expected_id == produced_id)
            installs = launcher == 'build-and-launch-computer.sh' and not arguments and expected_id == produced_id
            self.assertEqual(install_log.exists(), installs)
            if open_log.exists():
                self.assertEqual(open_log.read_text().strip(), str(installed if installs else app))

    def test_launchers_force_local_and_refuse_production_output_or_arguments(self):
        for launcher, builder, local, production in [
            ('build-and-launch.sh', 'build-app.sh', 'com.pdparchitect.noodle.local', 'com.pdparchitect.noodle'),
            ('build-and-launch-computer.sh', 'build-computer.sh', 'com.pdparchitect.noodle.computer.local',
             'com.pdparchitect.noodle.computer'),
            ('build-and-launch-applet.sh', 'xcode-build.sh', 'com.pdparchitect.noodle.applet.local',
             'com.pdparchitect.noodle.applet'),
            ('build-and-launch-hub.sh', 'xcode-build.sh', 'com.pdparchitect.noodle.hub.local',
             'com.pdparchitect.noodle.hub'),
            ('build-and-launch-browser.sh', 'xcode-build.sh', 'com.pdparchitect.noodle.browser.local',
             'com.pdparchitect.noodle.browser')]:
            with self.subTest(launcher=launcher):
                self.run_fixture(launcher, builder, local, local)
                self.run_fixture(launcher, builder, local, production)
                self.run_fixture(launcher, builder, local, local, ['--production-data'])


if __name__ == '__main__':
    unittest.main()
