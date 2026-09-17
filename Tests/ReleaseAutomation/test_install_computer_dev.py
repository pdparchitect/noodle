"""Exercise actual atomic publication in temporary folders, never /Applications."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('install_computer_local', ROOT / 'scripts/install-computer-dev.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class LocalComputerInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / '.build/Noodle Computer Dev.app'
        self.destination = self.root / 'Applications/Noodle Computer Dev.app'
        self.source.parent.mkdir()
        self.destination.parent.mkdir()
        self.bundle(self.source, 'new')

    def bundle(self, path, version, identifier=installer.LOCAL_ID):
        (path / 'Contents').mkdir(parents=True)
        (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        (path / 'Contents/version').write_text(version)

    def verify(self, path):
        self.assertTrue((path / 'Contents/version').is_file())

    def test_installs_and_preserves_the_old_service_path_as_an_alias(self):
        result = installer.install_local(self.source, self.destination, verify=self.verify)
        self.assertEqual(result, self.destination)
        self.assertTrue(self.source.is_symlink())
        self.assertEqual(self.source.resolve(), self.destination)
        self.assertEqual((self.source / 'Contents/version').read_text(), 'new')
        self.assertEqual(installer.install_local(self.source, self.destination, verify=self.verify), self.destination)

    def test_replaces_only_the_local_app_and_keeps_the_alias_valid(self):
        self.bundle(self.destination, 'old')
        production = self.destination.with_name('Noodle Computer.app')
        self.bundle(production, 'production', 'com.pdparchitect.noodle.computer')
        installer.install_local(self.source, self.destination, verify=self.verify)
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'new')
        self.assertEqual((production / 'Contents/version').read_text(), 'production')
        self.assertEqual(self.source.resolve(), self.destination)

    def test_refuses_a_production_bundle_at_the_destination(self):
        self.bundle(self.destination, 'production', 'com.pdparchitect.noodle.computer')
        with self.assertRaises(ValueError):
            installer.install_local(self.source, self.destination, verify=self.verify)
        self.assertFalse(self.source.is_symlink())
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'production')

    def test_refuses_a_destination_symlink(self):
        other = self.destination.with_name('Noodle Computer.app')
        self.bundle(other, 'production', 'com.pdparchitect.noodle.computer')
        self.destination.symlink_to(other)
        with self.assertRaises(ValueError):
            installer.install_local(self.source, self.destination, verify=self.verify)
        self.assertEqual((other / 'Contents/version').read_text(), 'production')

    def test_failed_alias_publication_rolls_back_the_installed_copy(self):
        self.bundle(self.destination, 'old')

        def exchange(staging, destination, replacing):
            if destination == self.source:
                raise OSError('injected alias publication failure')
            installer.publish(staging, destination, replacing)

        with self.assertRaises(OSError):
            installer.install_local(self.source, self.destination, verify=self.verify, exchange=exchange)
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'old')
        self.assertFalse(self.source.is_symlink())
        self.assertEqual((self.source / 'Contents/version').read_text(), 'new')

    def test_failed_final_validation_retains_the_previous_install(self):
        self.bundle(self.destination, 'old')

        def verify(path):
            if path == self.destination:
                raise ValueError('injected final verification failure')

        with self.assertRaises(ValueError):
            installer.install_local(self.source, self.destination, verify=verify)
        self.assertEqual((self.destination / 'Contents/version').read_text(), 'old')
        self.assertFalse(self.source.is_symlink())

    def test_dev_rename_preserves_both_registered_local_paths(self):
        legacy = self.destination.with_name('Noodle Computer Local.app')
        old_build = self.source.with_name(legacy.name)
        self.bundle(legacy, 'old')
        old_build.symlink_to(legacy)
        installer.install_local(self.source, self.destination, verify=self.verify, legacy_paths=(legacy, old_build))
        for path in (self.source, legacy, old_build):
            self.assertTrue(path.is_symlink())
            self.assertEqual(path.resolve(), self.destination)
            self.assertEqual((path / 'Contents/version').read_text(), 'new')

    def test_retired_local_aliases_are_not_recreated_by_later_builds(self):
        legacy = self.destination.with_name('Noodle Computer Local.app')
        old_build = self.source.with_name(legacy.name)
        installer.install_local(self.source, self.destination, verify=self.verify, legacy_paths=(legacy, old_build))
        self.assertFalse(legacy.exists())
        self.assertFalse(legacy.is_symlink())
        self.assertFalse(old_build.exists())
        self.assertFalse(old_build.is_symlink())
        self.assertEqual(self.source.resolve(), self.destination)

    def test_rename_failure_restores_old_app_and_all_aliases(self):
        legacy = self.destination.with_name('Noodle Computer Local.app')
        old_build = self.source.with_name(legacy.name)
        self.bundle(legacy, 'old')
        old_build.symlink_to(legacy)
        def exchange(staging, destination, replacing):
            if destination == old_build:
                raise OSError('injected legacy alias failure')
            installer.publish(staging, destination, replacing)
        with self.assertRaises(OSError):
            installer.install_local(self.source, self.destination, verify=self.verify,
                                    exchange=exchange, legacy_paths=(legacy, old_build))
        self.assertFalse(self.destination.exists())
        self.assertFalse(legacy.is_symlink())
        self.assertEqual((legacy / 'Contents/version').read_text(), 'old')
        self.assertEqual(old_build.resolve(), legacy)
        self.assertFalse(self.source.is_symlink())

    def test_rename_refuses_production_at_a_legacy_path(self):
        legacy = self.destination.with_name('Noodle Computer Local.app')
        self.bundle(legacy, 'production', 'com.pdparchitect.noodle.computer')
        with self.assertRaises(ValueError):
            installer.install_local(self.source, self.destination, verify=self.verify, legacy_paths=(legacy,))
        self.assertFalse(self.destination.exists())
        self.assertEqual((legacy / 'Contents/version').read_text(), 'production')


if __name__ == '__main__':
    unittest.main()
