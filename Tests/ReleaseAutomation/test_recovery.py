import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('recovery', ROOT / 'scripts/publish-prepared-release.py')
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)

class RecoveryTests(unittest.TestCase):
    def test_requires_completed_main_gates_and_prepared_artifacts(self):
        run = {'status': 'completed', 'head_branch': 'main', 'head_sha': 'a' * 40,
               'path': '.github/workflows/release.yml'}
        names = ['workflow-lint', 'versions', 'checks', 'tag', 'prepare-images / build', 'prepare-computer / release']
        jobs = [{'name': name, 'conclusion': 'success'} for name in names]
        artifacts = [{'name': name, 'expired': False} for name in ['computer-image-builds', 'computer-release-assets']]
        self.assertEqual(recovery.validate(run, jobs, artifacts), [
            ('images', 'computer-image-builds'), ('computer', 'computer-release-assets')])
        for name in names[:4]:
            failed = [dict(job, conclusion='failure') if job['name'] == name else job for job in jobs]
            with self.assertRaises(ValueError):
                recovery.validate(run, failed, artifacts)
        for changes in [{'status': 'in_progress'}, {'head_branch': 'feature'}, {'head_sha': 'invalid'}]:
            with self.assertRaises(ValueError):
                recovery.validate(dict(run, **changes), jobs, artifacts)
        with self.assertRaises(ValueError):
            recovery.validate(run, jobs, [])

    def test_applet_recovery_requires_its_verified_artifact(self):
        run = {'status': 'completed', 'head_branch': 'main', 'head_sha': 'a' * 40,
               'path': '.github/workflows/release.yml'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in
                ['workflow-lint', 'versions', 'checks', 'tag', 'prepare-applet / release']]
        artifacts = [{'name': 'applet-release-assets', 'expired': False}]
        self.assertEqual(recovery.validate(run, jobs, artifacts), [('applet', 'applet-release-assets')])
        with self.assertRaises(ValueError):
            recovery.validate(run, jobs, [{'name': 'applet-release-assets', 'expired': True}])

    def test_browser_recovery_requires_its_verified_artifact(self):
        run = {'status': 'completed', 'head_branch': 'main', 'head_sha': 'a' * 40,
               'path': '.github/workflows/release.yml'}
        jobs = [{'name': name, 'conclusion': 'success'} for name in
                ['workflow-lint', 'versions', 'checks', 'tag', 'prepare-browser / release']]
        artifacts = [{'name': 'browser-release-assets', 'expired': False}]
        self.assertEqual(recovery.validate(run, jobs, artifacts), [('browser', 'browser-release-assets')])
        with self.assertRaises(ValueError):
            recovery.validate(run, jobs, [{'name': 'browser-release-assets', 'expired': True}])

    def test_checksum_mismatch_and_path_escape_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'archive.zip').write_bytes(b'checked archive')
            digest = hashlib.sha256(b'checked archive').hexdigest()
            (root / 'checksum').write_text(digest + '  archive.zip\n')
            recovery.checksum(root, 'checksum')
            (root / 'archive.zip').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                recovery.checksum(root, 'checksum')
            (root / 'checksum').write_text(digest + '  ../archive.zip\n')
            with self.assertRaises(ValueError):
                recovery.checksum(root, 'checksum')

    def test_recovers_fixed_and_legacy_download_names_for_each_app(self):
        for product, prefix, platform in [('noodle', 'Noodle', 'macOS'),
                                          ('computer', 'Noodle-Computer', 'arm64'),
                                          ('applet', 'Noodle-Applet', 'arm64'),
                                          ('browser', 'Noodle-Browser', 'arm64')]:
            for name in [f'{prefix}-arm64.zip', f'{prefix}-1.2.3-{platform}.zip']:
                with self.subTest(product=product, archive=name), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / name).write_bytes(b'verified archive')
                    digest = hashlib.sha256(b'verified archive').hexdigest()
                    manifest = root / (name + '.sha256')
                    manifest.write_text(f'{digest}  {name}\n')
                    self.assertEqual(recovery.release_archive(root, product, '1.2.3'), name)
                    (root / name).write_bytes(b'modified archive')
                    with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                        recovery.release_archive(root, product, '1.2.3')

    def test_recovery_requires_one_archive_with_its_own_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
                recovery.release_archive(root, 'noodle', '1.2.3')
            name = 'Noodle-arm64.zip'
            (root / name).write_bytes(b'verified archive')
            (root / 'unrelated.zip').write_bytes(b'verified archive')
            digest = hashlib.sha256(b'verified archive').hexdigest()
            manifest = root / (name + '.sha256')
            manifest.write_text(f'{digest}  unrelated.zip\n')
            with self.assertRaisesRegex(ValueError, 'does not identify'):
                recovery.release_archive(root, 'noodle', '1.2.3')
            manifest.write_text(f'{digest}  {name}\n{digest}  unrelated.zip\n')
            with self.assertRaisesRegex(ValueError, 'exactly one'):
                recovery.release_archive(root, 'noodle', '1.2.3')
            manifest.write_text(f'{digest}  {name}\n')
            (root / 'Noodle-1.2.3-macOS.zip').write_bytes(b'legacy archive')
            with self.assertRaisesRegex(ValueError, 'Missing or ambiguous'):
                recovery.release_archive(root, 'noodle', '1.2.3')
