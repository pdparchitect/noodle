"""Exercise available and unavailable runners without installing any toolchain."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('detect_apple27', ROOT / 'scripts/detect-apple27.py')
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class Apple27DetectionTests(unittest.TestCase):
    def detect(self, version='27.0', architecture='arm64', developers=('/Xcode/Developer',), toolchains=None):
        values = {('sw_vers', '-productVersion'): version, ('uname', '-m'): architecture}
        with patch.object(PROBE, 'command', side_effect=lambda args: values[tuple(args)]), \
             patch.object(PROBE, 'full_xcodes', return_value=list(developers)), \
             patch.object(PROBE, 'toolchain', side_effect=lambda developer: (toolchains or {}).get(developer)) as lookup:
            result = PROBE.detect()
            return result, lookup.call_args_list

    def test_old_or_unknown_os_skips_before_querying_sdks(self):
        for version in ['26.6', '', 'unknown']:
            result, calls = self.detect(version=version)
            self.assertFalse(result['available'])
            self.assertIn('macOS 27', result['reason'])
            self.assertEqual(calls, [])

    def test_intel_and_missing_xctest_skip(self):
        for options in [{'architecture': 'x86_64'}, {'developers': []}]:
            result, calls = self.detect(**options)
            self.assertFalse(result['available'])
            self.assertEqual(calls, [])

    def test_new_os_without_sdk_skips(self):
        result, calls = self.detect()
        self.assertFalse(result['available'])
        self.assertIn('No installed macOS 27 SDK', result['reason'])
        self.assertEqual(len(calls), 2)  # Full Xcode, then CLT.

    def test_new_xcode_is_selected_without_changing_the_global_selection(self):
        newer = {'developer_dir': '/Xcode27/Developer', 'sdk': '/SDK27',
                 'swift': '/Xcode27/swift', 'sdk_version': '27.0'}
        result, calls = self.detect(developers=['/Xcode26/Developer', '/Xcode27/Developer'],
                                    toolchains={'/Xcode27/Developer': newer})
        self.assertTrue(result['available'])
        self.assertEqual(result['developer_dir'], newer['developer_dir'])
        self.assertEqual(result['swift'], newer['swift'])
        self.assertEqual(len(calls), 2)

    def test_clt_sdk_keeps_full_xcode_for_xctest(self):
        clt = '/Library/Developer/CommandLineTools'
        result, _ = self.detect(toolchains={clt: {'developer_dir': clt, 'sdk': '/CLT/SDK27',
                                                 'swift': '/CLT/swift', 'sdk_version': '27.0'}})
        self.assertTrue(result['available'])
        self.assertEqual(result['developer_dir'], '/Xcode/Developer')
        self.assertEqual(result['sdk'], '/CLT/SDK27')
        self.assertEqual(result['swift'], '/CLT/swift')

    def test_sdk_directory_and_compiler_must_really_exist(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sdk, swift = root / 'SDK27', root / 'swift'
            answers = {'--show-sdk-version': '27.0', '--show-sdk-path': str(sdk), 'swift': str(swift)}
            with patch.object(PROBE, 'command', side_effect=lambda args, developer: answers[args[-1]]):
                self.assertIsNone(PROBE.toolchain('/Xcode'))
                sdk.mkdir()
                swift.write_text('#!/bin/sh\n')
                self.assertIsNone(PROBE.toolchain('/Xcode'))
                swift.chmod(0o700)
                self.assertEqual(PROBE.toolchain('/Xcode')['sdk'], str(sdk.resolve()))
                answers['--show-sdk-version'] = '26.5'
                self.assertIsNone(PROBE.toolchain('/Xcode'))

    def test_missing_command_is_unavailable(self):
        with patch.object(PROBE.subprocess, 'check_output', side_effect=FileNotFoundError):
            self.assertEqual(PROBE.command(['missing']), '')

    def test_skip_and_success_are_reported_for_github_conditions(self):
        for available in [False, True]:
            with tempfile.TemporaryDirectory() as temporary:
                output, summary = Path(temporary) / 'outputs', Path(temporary) / 'summary'
                with patch.dict(os.environ, {'GITHUB_OUTPUT': str(output), 'GITHUB_STEP_SUMMARY': str(summary)}), \
                     contextlib.redirect_stdout(io.StringIO()):
                    PROBE.report({'available': available, 'reason': 'Test environment.'})
                self.assertIn(f'available={str(available).lower()}\n', output.read_text())
                self.assertIn('Available' if available else 'Skipped', summary.read_text())


if __name__ == '__main__':
    unittest.main()
