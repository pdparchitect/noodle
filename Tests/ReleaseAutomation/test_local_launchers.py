"""Launch guards use fake builders and open, never real apps or user data."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
APPS = ['Noodle', 'Computer', 'Applet', 'Browser', 'Hub']


class LocalLauncherTests(unittest.TestCase):
    def run_fixture(self, app_name, expected_id, produced_id, arguments=(), running=False, refused=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts, tools = root / 'scripts', root / 'tools'
            scripts.mkdir()
            tools.mkdir()
            shutil.copyfile(ROOT / 'scripts/build-and-launch.sh', scripts / 'build-and-launch.sh')
            builder = 'xcode-build.sh'
            app = root / 'Fixture.app'
            (app / 'Contents').mkdir(parents=True)
            with (app / 'Contents/Info.plist').open('wb') as output:
                plistlib.dump({'CFBundleIdentifier': produced_id}, output)
            (scripts / builder).write_text('''#!/bin/zsh
print -r -- "$NOODLE_DATA_CONTAINER/$NOODLE_COMPUTER_DATA_CONTAINER/$NOODLE_APPLET_DATA_CONTAINER/$NOODLE_BROWSER_DATA_CONTAINER/$NOODLE_HUB_DATA_CONTAINER/$*" > "$FIXTURE_BUILD_LOG"
print -r -- "$FIXTURE_APP"
''')
            (scripts / builder).chmod(0o700)
            (scripts / 'install-computer-dev.py').write_text('''import os, pathlib, sys
pathlib.Path(os.environ['FIXTURE_INSTALL_LOG']).write_text(sys.argv[1])
print(os.environ['FIXTURE_INSTALLED_APP'])
''')
            (tools / 'open').write_text('#!/bin/zsh\nprint -r -- "$*" > "$FIXTURE_OPEN_LOG"\n')
            (tools / 'open').chmod(0o700)
            # Asked to bring the app forward; never the real one.
            (tools / 'osascript').write_text('#!/bin/zsh\nprint -r -- "$*" > "$FIXTURE_ACTIVATE_LOG"\n')
            (tools / 'osascript').chmod(0o700)
            # Whether a copy of the app is already running.
            (tools / 'pgrep').write_text(f'#!/bin/zsh\nexit {0 if running else 1}\n')
            (tools / 'pgrep').chmod(0o700)
            build_log, open_log, install_log = root / 'build.log', root / 'open.log', root / 'install.log'
            activate_log = root / 'activate.log'
            installed = root / 'Applications/Fixture.app'
            launch = [] if app_name == 'Noodle' else [app_name]
            result = subprocess.run(['/bin/zsh', str(scripts / 'build-and-launch.sh'), *launch, *arguments],
                env=dict(os.environ, PATH=f'{tools}:/usr/bin:/bin',
                         NOODLE_DATA_CONTAINER='production', NOODLE_COMPUTER_DATA_CONTAINER='tests',
                         NOODLE_APPLET_DATA_CONTAINER='production',
                         NOODLE_BROWSER_DATA_CONTAINER='production',
                         NOODLE_HUB_DATA_CONTAINER='production', FIXTURE_APP=str(app),
                         FIXTURE_INSTALLED_APP=str(installed), FIXTURE_INSTALL_LOG=str(install_log),
                         FIXTURE_BUILD_LOG=str(build_log), FIXTURE_OPEN_LOG=str(open_log),
                         FIXTURE_ACTIVATE_LOG=str(activate_log)),
                capture_output=True, text=True)
            if refused is None:
                refused = bool(arguments) or app_name not in APPS
            if refused:
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(build_log.exists())
            else:
                fields = build_log.read_text().strip().split('/')
                # Every app builds with one script, told which app to build.
                container = APPS.index(app_name)
                self.assertEqual((fields[container], fields[5]), ('development', app_name))
                self.assertEqual(result.returncode, 0 if expected_id == produced_id else 1, result.stderr)
            self.assertEqual(open_log.exists(), not refused and expected_id == produced_id)
            if open_log.exists():
                # AppKit opens any argument that is not a flag as a file, and then no window.
                self.assertTrue(all(word.startswith('-') for word in open_log.read_text().split()[2:]))
            installs = app_name == 'Computer' and not refused and expected_id == produced_id
            self.assertEqual(install_log.exists(), installs)
            # What was opened is brought forward, by its path, whoever started the launcher.
            self.assertEqual(activate_log.exists(), open_log.exists())
            if activate_log.exists():
                self.assertEqual(activate_log.read_text().strip(),
                                 f'-e tell application "{installed if installs else app}" to activate')
            if open_log.exists():
                opened = str(installed if installs else app)
                if '--rehearse' in arguments:
                    opened += ' --args --rehearse'
                self.assertEqual(open_log.read_text().strip(), opened)
            return result

    def test_launcher_forces_local_and_refuses_production_output_or_arguments(self):
        for app_name, local in [('Noodle', 'com.pdparchitect.noodle.local'),
                                ('Computer', 'com.pdparchitect.noodle.computer.local'),
                                ('Applet', 'com.pdparchitect.noodle.applet.local'),
                                ('Browser', 'com.pdparchitect.noodle.browser.local'),
                                ('Hub', 'com.pdparchitect.noodle.hub.local')]:
            with self.subTest(app=app_name):
                self.run_fixture(app_name, local, local)
                self.run_fixture(app_name, local, local.removesuffix('.local'))
                self.run_fixture(app_name, local, local, ['--production-data'])

    def test_a_rehearsal_opens_noodle_dev_afresh_and_only_noodle_dev(self):
        local = 'com.pdparchitect.noodle.local'
        self.run_fixture('Noodle', local, local, ['--rehearse'], refused=False)
        self.run_fixture('Noodle', local, local.removesuffix('.local'), ['--rehearse'], refused=False)
        # A running copy would only come forward, still showing its own data.
        self.run_fixture('Noodle', local, local, ['--rehearse'], running=True, refused=True)
        self.run_fixture('Computer', 'com.pdparchitect.noodle.computer.local', 'com.pdparchitect.noodle.computer.local',
                         ['--rehearse'])

    def test_launcher_refuses_an_unknown_app(self):
        self.run_fixture('Website', 'com.pdparchitect.noodle.website.local', 'com.pdparchitect.noodle.website.local')

if __name__ == '__main__':
    unittest.main()
