"""Exercise shader selection on build hosts where runtime models are unavailable."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ApplePackagingTests(unittest.TestCase):
    def test_compiled_capabilities_control_shaders_and_release_requirements(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            tools = root / 'tools'
            binary = root / '.build/bin'
            for path in [scripts, tools, binary]:
                path.mkdir(parents=True)
            (root / 'VERSION').write_text('0.16.0\n')
            (binary / 'Noodle').touch()
            shutil.copyfile(ROOT / 'scripts/build-app.sh', scripts / 'build-app.sh')
            for path, body in {
                tools / 'xcodebuild': 'exit 0',
                tools / 'xcrun': 'printf "26.5\\n"',
                scripts / 'swift-apple.sh': 'printf "%s\\n" "$FIXTURE_BIN"',
                scripts / 'build-mlx-metal.sh': 'touch "$FIXTURE_METAL_LOG"',
                binary / 'NoodleAppleAgent': 'case "$1" in --build-capabilities) printf \'{"apple27":%s}\\n\' "$FIXTURE_APPLE27";; --inspect) printf \'{"localModelsSupported":false}\\n\';; *) exit 2;; esac',
                # Stop the real build before packaging or signing starts.
                binary / 'NoodleDocumentation': 'exit 99',
            }.items():
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o700)
            for compiled, required, expected in [('true', '1', 99), ('false', '1', 1), ('false', '0', 99)]:
                with self.subTest(compiled=compiled, required=required):
                    metal = root / 'metal-built'
                    metal.unlink(missing_ok=True)
                    result = subprocess.run(['/bin/zsh', str(scripts / 'build-app.sh')],
                        env=dict(os.environ, PATH=f'{tools}:/usr/bin:/bin',
                                 NOODLE_DATA_CONTAINER='development', NOODLE_REQUIRE_DEVELOPER_ID='0',
                                 NOODLE_REQUIRE_APPLE27=required, NOODLE_BUILD_NUMBER='0.16.0',
                                 FIXTURE_BIN=str(binary), FIXTURE_APPLE27=compiled, FIXTURE_METAL_LOG=str(metal)),
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual(metal.exists(), compiled == 'true')
                    if expected == 1:
                        self.assertIn('requires an Apple helper compiled with the macOS 27 SDK', result.stderr)


if __name__ == '__main__':
    unittest.main()
