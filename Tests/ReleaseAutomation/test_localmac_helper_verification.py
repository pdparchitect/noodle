"""Check the signed-helper policy without creating accounts or changing consent."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
AUTOMATION = 'com.apple.security.automation.apple-events'


class LocalMacHelperVerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        cls.verifier = cls.root / 'verify-localmac-helper'
        subprocess.run(['swiftc', str(ROOT / 'Computer/Tests/VerifyLocalMacHelper.swift'),
                        '-module-cache-path', str(cls.root / 'ModuleCache'),
                        '-o', str(cls.verifier)], check=True)

    def verify(self, entitlements, name='LocalMacDesktop.app', description=True):
        bundle = self.root / name
        if name.endswith('.app'):
            contents = bundle / 'Contents'
            contents.mkdir(parents=True, exist_ok=True)
            info = plistlib.loads((ROOT / 'Computer/Support/LocalMacDesktop-Info.plist').read_bytes())
            if not description:
                info.pop('NSAppleEventsUsageDescription', None)
            (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        signed = self.root / 'signed-entitlements.plist'
        signed.write_bytes(plistlib.dumps(entitlements) if entitlements is not None else b'')
        return subprocess.run([str(self.verifier), str(bundle), str(signed)],
                              capture_output=True, text=True, timeout=10)

    def test_desktop_consent_entitlement_passes(self):
        result = self.verify({AUTOMATION: True})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_or_disabled_consent_entitlement_fails(self):
        for entitlements in [None, {}, {AUTOMATION: False}]:
            with self.subTest(entitlements=entitlements):
                result = self.verify(entitlements)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('only the Apple Events consent entitlement', result.stderr)

    def test_extra_desktop_entitlement_fails(self):
        result = self.verify({AUTOMATION: True, 'com.apple.security.network.server': True})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('only the Apple Events consent entitlement', result.stderr)

    def test_missing_usage_description_fails(self):
        result = self.verify({AUTOMATION: True}, description=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('NSAppleEventsUsageDescription', result.stderr)

    def test_setup_and_service_keep_empty_entitlements(self):
        for name in ['LocalMacSetup.app', 'LocalMacService']:
            with self.subTest(name=name):
                result = self.verify(None, name=name)
                self.assertEqual(result.returncode, 0, result.stderr)
                result = self.verify({AUTOMATION: True}, name=name)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('must not carry optional entitlements', result.stderr)


if __name__ == '__main__':
    unittest.main()
