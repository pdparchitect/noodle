import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2]


def run(*args, cwd, check=True, env=None):
    return subprocess.run(args, cwd=cwd, check=check, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'source'
        self.remote = Path(self.temp.name) / 'origin.git'
        self.root.mkdir()
        run('git', 'init', '--bare', str(self.remote), cwd=self.root)
        run('git', 'init', cwd=self.root)
        self.git('config', 'user.name', 'Release test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('remote', 'add', 'origin', str(self.remote))
        (self.root / 'scripts').mkdir()
        shutil.copy(SOURCE / 'scripts/release-versions.py', self.root / 'scripts')
        spec = importlib.util.spec_from_file_location('release_versions', self.root / 'scripts/release-versions.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        for product in self.module.PRODUCTS:
            self.write_version(product, '1.0.0')
        self.commit()
        for product in self.module.PRODUCTS:
            self.git('tag', self.module.version(product)[1])
        self.git('push', 'origin', '--tags')

    def git(self, *args):
        return run('git', *args, cwd=self.root).stdout.strip()

    def commit(self):
        self.git('add', '.')
        self.git('commit', '-m', 'Fixture')

    def write_version(self, product, value, body='- A release change.'):
        path, changelog, _ = self.module.PRODUCTS[product]
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(value + '\n')
        (self.root / changelog).write_text(f'## Unreleased\n\n## [{value}] - 2026-09-10\n\n{body}\n')

    def test_unchanged_versions_do_not_release_even_with_source_changes(self):
        (self.root / 'new-code.txt').write_text('new code')
        self.commit()
        self.assertEqual(self.module.plan(), [])

    def test_independent_versions_and_numeric_ordering(self):
        self.write_version('computer', '1.10.0')
        self.write_version('images', '1.0.1')
        self.assertEqual(self.module.plan(), ['computer', 'images'])
        self.assertEqual(self.module.version('computer')[1], 'computer-v1.10.0')

    def test_rollback_rejected_even_if_old_tag_exists(self):
        self.git('tag', 'computer-v2.0.0')
        with self.assertRaisesRegex(ValueError, 'roll back'):
            self.module.plan()

    def test_invalid_versions_and_notes_fail_before_tagging(self):
        for value in ['1.2', '01.2.3', '1.2.3-beta', '1.2.3\n4.5.6', 'v1.2.3']:
            with self.subTest(value=value):
                self.write_version('computer', value)
                with self.assertRaises(ValueError):
                    self.module.plan()
        self.write_version('computer', '1.2.3', body='')
        with self.assertRaisesRegex(ValueError, 'no release notes'):
            self.module.plan()
        self.write_version('computer', '1.2.3')
        (self.root / 'Computer/CHANGELOG.md').write_text('## Unreleased\n- Notes\n')
        with self.assertRaisesRegex(ValueError, 'dated section'):
            self.module.plan()

    def test_all_tags_derive_from_files_and_retry_keeps_same_commit(self):
        self.write_version('computer', '1.2.0')
        self.write_version('images', '1.0.1')
        self.commit()
        self.module.mint(['computer', 'images'])
        first = self.git('ls-remote', '--tags', 'origin')
        self.module.mint(['computer', 'images'])
        self.assertEqual(first, self.git('ls-remote', '--tags', 'origin'))
        self.assertIn('refs/tags/computer-v1.2.0', first)
        self.assertIn('refs/tags/computer-images-v1.0.1', first)
        self.assertNotIn('refs/tags/v1.2.0', first)

    def test_conflicting_existing_tag_blocks_every_new_tag(self):
        self.write_version('computer', '1.2.0')
        self.write_version('images', '1.0.1')
        self.commit()
        self.git('tag', 'computer-images-v1.0.1', 'HEAD~1')
        with self.assertRaisesRegex(ValueError, 'another commit'):
            self.module.mint(['computer', 'images'])
        self.assertNotIn('computer-v1.2.0', self.git('tag', '--list'))

    def test_remote_race_rejects_entire_atomic_push(self):
        self.write_version('computer', '1.2.0')
        self.write_version('images', '1.0.1')
        self.commit()
        self.git('push', 'origin', 'HEAD~1:refs/tags/computer-images-v1.0.1')
        with self.assertRaises(subprocess.CalledProcessError):
            self.module.mint(['computer', 'images'])
        remote = self.git('ls-remote', '--tags', 'origin')
        self.assertNotIn('refs/tags/computer-v1.2.0', remote)

    def test_dirty_tracked_sources_cannot_be_tagged(self):
        self.write_version('computer', '1.2.0')
        with self.assertRaisesRegex(ValueError, 'modified tracked files'):
            self.module.mint(['computer'])

    def test_first_applet_release_requires_dated_notes(self):
        self.git('tag', '-d', 'applet-v1.0.0')
        (self.root / 'Applet/CHANGELOG.md').write_text('## [Unreleased]\n\n- Initial work.\n')
        self.assertEqual(self.module.plan(), [])
        with self.assertRaisesRegex(ValueError, 'dated section'):
            self.module.notes('applet')
        self.write_version('applet', '1.0.0')
        self.assertEqual(self.module.plan(), ['applet'])
        self.assertEqual(self.module.version('applet')[1], 'applet-v1.0.0')

    def test_ci_outputs_are_derived_from_version_files(self):
        self.write_version('images', '1.0.1')
        result = run('python3', 'scripts/release-versions.py', 'plan', cwd=self.root)
        outputs = dict(line.split('=', 1) for line in result.stdout.splitlines())
        self.assertEqual(json.loads(outputs['products']), ['images'])
        self.assertEqual(outputs['computer'], 'false')
        self.assertEqual(outputs['images'], 'true')


if __name__ == '__main__':
    unittest.main()
