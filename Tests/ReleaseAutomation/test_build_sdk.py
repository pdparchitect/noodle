"""Keep deployment-target metadata from masquerading as the linked macOS SDK."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('verify_build_sdk', ROOT / 'scripts/verify-build-sdk.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class BuildSDKTests(unittest.TestCase):
    def test_old_deployment_target_with_current_sdk_is_valid(self):
        CHECK.verify('    minos 15.0\n      sdk 26.5\n', '26.5')

    def test_native_engine_regression_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Linked SDK 15.0'):
            CHECK.verify('    minos 15.0\n      sdk 15.0\n', '26.5')

    def test_every_architecture_must_match(self):
        with self.assertRaises(ValueError):
            CHECK.verify('      sdk 26.5\n      sdk 15.0\n', '26.5')
        CHECK.verify('      sdk 26.5\n      sdk 26.5\n', '26.5.0')

    def test_missing_sdk_metadata_is_rejected(self):
        with self.assertRaises(ValueError):
            CHECK.verify('    minos 15.0\n', '26.5')

    def test_wrapper_supplies_the_selected_sdk_to_direct_toolchains(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executables = {
                'xcrun': 'printf "%s\\n" "$NOODLE_TEST_XCODE_SDK"',
                'xcode-select': 'printf "%s\\n" "$NOODLE_TEST_DEVELOPER"',
                'xcodebuild': 'exit 0',
                'swift': 'printf "%s\\n" "$SDKROOT" "$@"',
            }
            for name, body in executables.items():
                path = root / name
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o700)
            xcode_sdk = root / 'MacOSX26.5.sdk'
            for sdk in [xcode_sdk, root / 'MacOSX27.0.sdk']:
                for command in ['build', 'package']:
                    with self.subTest(sdk=sdk.name, command=command):
                        env = dict(os.environ, PATH=f'{root}:/usr/bin:/bin',
                                   NOODLE_SWIFT=str(root / 'swift'), NOODLE_MACOS_SDK=str(sdk),
                                   NOODLE_TEST_XCODE_SDK=str(xcode_sdk),
                                   NOODLE_TEST_DEVELOPER=str(root / 'Developer'),
                                   DEVELOPER_DIR=str(root / 'Developer'), SDKROOT='/wrong/inherited/sdk')
                        result = subprocess.run(['/bin/zsh', str(ROOT / 'scripts/swift-apple.sh'), command],
                                                env=env, capture_output=True, text=True, check=True)
                        arguments = result.stdout.splitlines()
                        self.assertEqual(arguments[0], str(sdk))
                        self.assertEqual(arguments[arguments.index('--sdk') + 1], str(sdk))
                        if command == 'build':
                            self.assertIn('-syslibroot', arguments)
                            self.assertEqual(arguments[arguments.index('-syslibroot') + 2], str(sdk))
                        else:
                            self.assertNotIn('-Xlinker', arguments)


if __name__ == '__main__':
    unittest.main()
