"""Exercise installer signing failures and publication without release credentials."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def executable(path, body):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/zsh\nset -eu\n' + body)
    path.chmod(0o700)


class DiskImagePackagingTests(unittest.TestCase):
    def test_only_final_verified_bytes_are_exported(self):
        for failure in ['', 'notarytool', 'staple', 'spctl', 'build']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'scripts').mkdir()
                shutil.copyfile(ROOT / 'scripts/package-dmg.sh', root / 'scripts/package-dmg.sh')
                app = root / 'Noodle Computer.app'
                app.mkdir()
                executable(root / '.build/dmg-tools/bin/python', '''
if [[ "$1" == -m ]]; then exit 0; fi
print 'build' >> "$TEST_LOG"
[[ "$TEST_FAILURE" != build ]] || exit 1
print -n 'image' > "$4"
''')
                executable(root / 'bin/swift', 'print -n background > "${@: -1}"\n')
                executable(root / 'bin/codesign', 'print "codesign $*" >> "$TEST_LOG"\n')
                executable(root / 'bin/xcrun', '''
print "xcrun $*" >> "$TEST_LOG"
[[ "$1" != "$TEST_FAILURE" && "$2" != "$TEST_FAILURE" ]] || exit 1
if [[ "$1 $2" == 'stapler staple' ]]; then print -n ticket >> "$3"; fi
''')
                executable(root / 'bin/spctl', '''
print "spctl $*" >> "$TEST_LOG"
[[ "$TEST_FAILURE" != spctl ]]
''')
                environment = dict(os.environ, PATH=f'{root}/bin:' + os.environ['PATH'],
                                   TEST_LOG=str(root / 'commands'), TEST_FAILURE=failure,
                                   NOODLE_SIGNING_IDENTITY='Developer ID Application: Fixture',
                                   APPLE_API_KEY_PATH='/fixture/key', APPLE_API_KEY_ID='fixture',
                                   APPLE_API_ISSUER_ID='fixture')
                output = root / 'dist/Noodle-Computer-arm64.dmg'
                result = subprocess.run(['zsh', str(root / 'scripts/package-dmg.sh'), str(app), str(output)],
                                        env=environment, capture_output=True, text=True)
                if failure:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                    self.assertFalse(Path(str(output) + '.sha256').exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(output.read_bytes(), b'imageticket')
                    checksum = Path(str(output) + '.sha256').read_text().split()[0]
                    self.assertEqual(checksum, hashlib.sha256(b'imageticket').hexdigest())
                    commands = (root / 'commands').read_text()
                    ordered = ['stapler validate', 'build', 'codesign --force', 'notarytool submit',
                               'stapler staple', 'spctl --assess']
                    positions = [commands.index(command) for command in ordered]
                    self.assertEqual(positions, sorted(positions))
                    retry = subprocess.run(['zsh', str(root / 'scripts/package-dmg.sh'), str(app), str(output)],
                                           env=environment, capture_output=True, text=True)
                    self.assertNotEqual(retry.returncode, 0)
                    self.assertIn('Output already exists', retry.stderr)
                    self.assertEqual((root / 'commands').read_text(), commands)


class DiskImagePublicationTests(unittest.TestCase):
    def test_companion_channels_include_verified_disk_images_before_feeds(self):
        for product in ['Computer', 'Applet', 'Browser', 'Hub']:
            for scenario in ['new', 'existing-channel', 'corrupt-dmg', 'missing-dmg']:
                with self.subTest(product=product, scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    (root / product).mkdir()
                    (root / product / 'VERSION').write_text('1.2.3\n')
                    (root / 'scripts').mkdir()
                    script = f'publish-{product.lower()}-release.sh'
                    shutil.copyfile(ROOT / 'scripts' / script, root / 'scripts' / script)
                    assets = root / 'dist' / f'{product.lower()}-1.2.3'
                    assets.mkdir(parents=True)
                    for suffix in ['zip', 'dmg']:
                        name = f'Noodle-{product}-arm64.{suffix}'
                        (assets / name).write_bytes(b'prepared')
                        digest = hashlib.sha256(b'prepared').hexdigest()
                        (assets / (name + '.sha256')).write_text(f'{digest}  {name}\n')
                    (assets / 'appcast.xml').write_text('signed feed')
                    (assets / 'notes.md').write_text('release notes')
                    image = assets / f'Noodle-{product}-arm64.dmg'
                    if scenario == 'corrupt-dmg':
                        image.write_bytes(b'changed')
                    if scenario == 'missing-dmg':
                        image.unlink()
                    executable(root / 'bin/gh', '''
print "$*" >> "$TEST_LOG"
if [[ "$1" == api ]]; then print false; fi
if [[ "$1 $2" == 'release view' ]]; then
    if [[ "$3" == *-latest && "$TEST_SCENARIO" == existing-channel ]]; then
        if [[ "$*" == *--json\ name* ]]; then print "Noodle $TEST_PRODUCT 1.2.2"; fi
    else
        exit 1
    fi
fi
''')
                    executable(root / 'bin/git', 'print fixture-commit\n')
                    log = root / 'commands'
                    log.touch()
                    result = subprocess.run(['zsh', str(root / 'scripts' / script), '1.2.3', str(assets / 'notes.md')],
                        env=dict(os.environ, PATH=f'{root}/bin:' + os.environ['PATH'], TEST_LOG=str(log),
                                 TEST_SCENARIO=scenario, TEST_PRODUCT=product), capture_output=True, text=True)
                    commands = log.read_text().splitlines()
                    if scenario in ['missing-dmg', 'corrupt-dmg']:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(commands, [])
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        creates = [line for line in commands if line.startswith('release create')]
                        self.assertEqual(len(creates), 2 if scenario == 'new' else 1)
                        for line in creates:
                            self.assertIn(str(image), line)
                            self.assertIn(str(image) + '.sha256', line)
                        if scenario == 'existing-channel':
                            uploads = [line for line in commands if line.startswith('release upload')]
                            self.assertIn(str(image), uploads[0])
                            self.assertIn(str(image) + '.sha256', uploads[0])
                            self.assertNotIn('appcast.xml', uploads[0])
                            self.assertIn('appcast.xml', uploads[1])


if __name__ == '__main__':
    unittest.main()
