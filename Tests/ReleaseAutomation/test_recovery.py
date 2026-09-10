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
