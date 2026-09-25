"""Suite reuse, pinning, and publication guards without network or credentials."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('suite', ROOT / 'scripts/suite-release.py')
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)


class GitHubFixture:
    def __init__(self):
        self.items = []
        self.files = {}
        self.downloads = []
        for product in ['noodle', 'computer', 'applet']:
            self.app(product, '1.2.3')

    def app(self, product, version, draft=False, prerelease=False, legacy=False):
        prefix, name, _ = suite.PRODUCTS[product]
        tag = prefix + version
        basename = name.replace(' ', '-')
        suffix = f'{version}-' + ('macOS' if product == 'noodle' else 'arm64') if legacy else 'arm64'
        archive = f'{basename}-{suffix}.zip'
        data = tag.encode()
        self.release(tag, {archive: data, archive + '.sha256':
                           f'{hashlib.sha256(data).hexdigest()}  {archive}\n'.encode()}, draft, prerelease)

    def release(self, tag, files, draft=False, prerelease=False):
        self.items = [item for item in self.items if item['tag_name'] != tag]
        self.items.append(dict(tag_name=tag, draft=draft, prerelease=prerelease,
                               assets=[{'name': name} for name in files]))
        self.files.update({(tag, name): value for name, value in files.items()})

    def snapshot(self, tag, manifest, draft=False):
        self.release(tag, {
            suite.IMAGE: b'verified image',
            suite.IMAGE + '.sha256': f'{hashlib.sha256(b"verified image").hexdigest()}  {suite.IMAGE}\n'.encode(),
            suite.MANIFEST: json.dumps(manifest).encode(),
        }, draft=draft)

    def releases(self):
        return copy.deepcopy(self.items)

    def download(self, release, names, directory):
        directory.mkdir(parents=True, exist_ok=True)
        for name in names:
            self.downloads.append((release['tag_name'], name))
            (directory / name).write_bytes(self.files[(release['tag_name'], name)])


class SuiteTests(unittest.TestCase):
    def setUp(self):
        self.github = GitHubFixture()
        self.recipe = 'a' * 64

    def plan(self):
        return suite.plan(self.github, self.recipe)

    def test_planning_downloads_only_checksums_and_uses_numeric_stable_versions(self):
        self.github.app('computer', '1.9.0')
        self.github.app('computer', '1.10.0')
        self.github.app('computer', '2.0.0', draft=True)
        self.github.app('computer', '3.0.0', prerelease=True)
        planned = self.plan()
        self.assertEqual(planned['action'], 'build')
        self.assertEqual([item['version'] for item in planned['manifest']['components']], ['1.2.3', '1.10.0', '1.2.3'])
        self.assertTrue(all(name.endswith('.zip.sha256') for _, name in self.github.downloads))
        self.assertEqual(suite.snapshot_tag(planned['manifest']), planned['tag'])

    def test_unchanged_inputs_skip_everything_and_a_computer_patch_reuses_other_apps(self):
        initial = self.plan()
        self.github.snapshot(initial['tag'], initial['manifest'])
        self.github.snapshot(suite.CHANNEL, initial['manifest'])
        self.assertEqual(self.plan()['action'], 'none')
        self.github.app('computer', '1.2.4')
        updated = self.plan()
        self.assertEqual(updated['action'], 'build')
        before = {item['product']: item for item in initial['manifest']['components']}
        after = {item['product']: item for item in updated['manifest']['components']}
        for product in ['noodle', 'applet']:
            self.assertEqual(before[product], after[product])
        self.assertNotEqual(initial['tag'], updated['tag'])
        self.assertEqual(after['computer']['version'], '1.2.4')

    def test_unpublished_browser_is_optional_and_joins_after_its_first_stable_release(self):
        initial = self.plan()
        self.github.app('browser', '0.1.0', draft=True)
        self.assertEqual(self.plan(), initial)
        self.github.app('browser', '0.1.0')
        updated = self.plan()
        self.assertEqual(updated['manifest']['components'][-1]['product'], 'browser')
        self.assertEqual(updated['manifest']['components'][:3], initial['manifest']['components'])

    def test_hub_joins_the_suite_after_its_first_stable_release(self):
        initial = self.plan()
        self.github.app('hub', '0.2.0', prerelease=True)
        self.assertEqual(self.plan(), initial)
        self.github.app('hub', '0.2.0')
        updated = self.plan()
        self.assertEqual(updated['manifest']['components'][-1]['product'], 'hub')
        self.assertEqual(updated['manifest']['components'][-1]['archive'], 'Noodle-Hub-arm64.zip')

    def test_channel_failure_reuses_the_existing_snapshot_without_repackaging(self):
        planned = self.plan()
        self.github.snapshot(planned['tag'], planned['manifest'], draft=True)
        reused = self.plan()
        self.assertEqual(reused['action'], 'reuse')
        self.github.downloads.clear()
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'command') as command:
            directory = Path(temporary)
            suite.fetch(self.github, reused, directory)
            suite.verify_assets(directory / 'assets', planned['manifest'])
            command.assert_not_called()  # No compilation, extraction, signing, or notarization.
        self.assertEqual(self.github.downloads, [(planned['tag'], name) for name in suite.ASSETS])

    def test_missing_or_corrupt_existing_snapshots_fail_without_rebuilding(self):
        planned = self.plan()
        self.github.release(planned['tag'], {}, draft=True)
        with self.assertRaisesRegex(ValueError, 'Incomplete Suite snapshot'):
            self.plan()
        self.github.snapshot(planned['tag'], planned['manifest'])
        reused = self.plan()
        self.github.files[(planned['tag'], suite.IMAGE)] = b'corrupted'
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
            suite.fetch(self.github, reused, Path(temporary))

    def test_checksum_manifest_must_name_the_exact_archive(self):
        tag, name = next(key for key in self.github.files if key[1].endswith('.sha256'))
        self.github.files[(tag, name)] = (('a' * 64) + '  other.zip\n').encode()
        with self.assertRaisesRegex(ValueError, 'Invalid checksum'):
            self.plan()

    def test_source_corruption_is_rejected_before_extraction(self):
        planned = self.plan()
        item = planned['manifest']['components'][0]
        self.github.files[(item['tag'], item['archive'])] = b'corrupted'
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'Checksum mismatch'):
                suite.fetch(self.github, planned, Path(temporary))
            command.assert_not_called()

    def test_legacy_archives_can_be_reused_without_building_old_apps(self):
        for product in ['noodle', 'computer', 'applet']:
            self.github.app(product, '1.2.3', legacy=True)
        planned = self.plan()
        self.assertEqual(planned['manifest']['components'][0]['archive'], 'Noodle-1.2.3-macOS.zip')
        self.assertEqual(planned['manifest']['components'][1]['archive'], 'Noodle-Computer-1.2.3-arm64.zip')

    def test_archive_cache_reuses_unchanged_apps_and_repairs_corrupt_entries(self):
        component = self.plan()['manifest']['components'][0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cache = root / 'cache'
            self.github.downloads.clear()
            first = suite.app_archive(self.github, component, root / 'first', cache)
            self.assertEqual(len(self.github.downloads), 1)
            cached = suite.app_archive(self.github, component, root / 'second', cache)
            self.assertEqual(len(self.github.downloads), 1)
            self.assertEqual(first.read_bytes(), cached.read_bytes())
            cached.write_bytes(b'corrupt cache')
            repaired = suite.app_archive(self.github, component, root / 'third', cache)
            self.assertEqual(len(self.github.downloads), 2)
            suite.verify_checksum(repaired, component['sha256'])
            suite.verify_checksum(cached, component['sha256'])

    def test_only_packaging_inputs_change_the_recipe(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'ROOT', Path(temporary)):
            for name in suite.RECIPE_FILES:
                path = Path(temporary) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
            before = suite.recipe_digest()
            (Path(temporary) / 'README.md').write_text('A documentation change')
            (Path(temporary) / 'App.swift').write_text('An unreleased source edit')
            self.assertEqual(suite.recipe_digest(), before)
            (Path(temporary) / 'scripts/dmg-background.swift').write_text('A changed installer design')
            self.assertNotEqual(suite.recipe_digest(), before)

    def test_fetch_uses_cached_original_bundles_and_downloads_only_the_patched_app(self):
        def archive(product, version):
            self.github.app(product, version)
            prefix, name, bundle_id = suite.PRODUCTS[product]
            tag, filename = prefix + version, name.replace(' ', '-') + '-arm64.zip'
            content = io.BytesIO()
            with zipfile.ZipFile(content, 'w') as zipped:
                zipped.writestr(name + '.app/Contents/Info.plist', plistlib.dumps({
                    'CFBundleIdentifier': bundle_id, 'CFBundleShortVersionString': version}))
            data = content.getvalue()
            self.github.files[(tag, filename)] = data
            self.github.files[(tag, filename + '.sha256')] = f'{hashlib.sha256(data).hexdigest()}  {filename}\n'.encode()

        for product in ['noodle', 'computer', 'applet']:
            archive(product, '1.2.3')
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'verify_app', return_value='TEAM'), \
                patch.object(suite, 'command', wraps=suite.command) as command:
            root = Path(temporary)
            cache = root / 'cache'
            initial = self.plan()
            suite.fetch(self.github, initial, root / 'initial', cache)
            archive('computer', '1.2.4')
            updated = self.plan()
            self.github.downloads.clear()
            suite.fetch(self.github, updated, root / 'updated', cache)
            self.assertEqual(self.github.downloads, [('computer-v1.2.4', 'Noodle-Computer-arm64.zip')])
            for name in ['Noodle', 'Noodle Applet']:
                relative = f'apps/{name}.app/Contents/Info.plist'
                self.assertEqual((root / 'initial' / relative).read_bytes(), (root / 'updated' / relative).read_bytes())
            self.assertEqual(len(list(cache.glob('*.zip'))), 3)
            self.assertTrue(all(call.args[0] == 'ditto' for call in command.call_args_list))

    def test_bundles_must_keep_the_expected_identity_version_and_update_feed(self):
        component = self.plan()['manifest']['components'][0]
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Noodle.app'
            (app / 'Contents').mkdir(parents=True)
            info = {'CFBundleIdentifier': suite.PRODUCTS['noodle'][2], 'CFBundleShortVersionString': '1.2.3',
                    'SUFeedURL': f'https://github.com/{suite.REPO}/releases/latest/download/appcast.xml',
                    'LSMinimumSystemVersion': '15.0', 'CFBundleExecutable': 'Noodle'}
            for field, value, error in [
                ('CFBundleIdentifier', 'example.fake', 'identity/version'),
                ('CFBundleShortVersionString', '1.2.4', 'identity/version'),
                ('SUFeedURL', 'https://example.com/appcast.xml', 'updater channel'),
                ('LSMinimumSystemVersion', '27.0', 'newer macOS'),
            ]:
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({**info, field: value}))
                with self.subTest(field=field), patch.object(suite, 'command') as command:
                    with self.assertRaisesRegex(ValueError, error):
                        suite.verify_app(app, component)
                    command.assert_not_called()

    def assets(self, directory, planned):
        self.github.snapshot(planned['tag'], planned['manifest'])
        self.github.download({'tag_name': planned['tag']}, suite.ASSETS, directory)
        (directory / 'release-notes.md').write_text(suite.release_notes(planned['manifest']))

    def test_stale_assembly_never_promotes_over_a_newer_app_release(self):
        planned = self.plan()
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'recipe_digest', return_value=self.recipe), \
                patch.object(suite, 'command') as command:
            directory = Path(temporary)
            self.assets(directory, planned)
            self.github.app('computer', '1.2.4')
            suite.publish(self.github, planned, directory, 'a' * 40)
            command.assert_not_called()

    def test_promotion_keeps_noodle_latest_and_never_overwrites_immutable_assets(self):
        planned = self.plan()
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'recipe_digest', return_value=self.recipe), \
                patch.object(suite, 'command') as command:
            directory = Path(temporary)
            self.assets(directory, planned)
            planned['action'] = 'reuse'
            suite.publish(self.github, planned, directory, 'a' * 40)
            calls = [call.args for call in command.call_args_list]
            self.assertEqual(calls[0][:4], ('gh', 'release', 'edit', planned['tag']))
            self.assertEqual(calls[1][:4], ('gh', 'release', 'create', suite.CHANNEL))
            self.assertTrue(all('--latest=false' in call for call in calls))
            self.assertFalse(any('--clobber' in call for call in calls))
            self.github.snapshot(suite.CHANNEL, planned['manifest'])
            command.reset_mock()
            suite.publish(self.github, planned, directory, 'a' * 40)
            for call in command.call_args_list:
                if '--clobber' in call.args:
                    self.assertEqual(call.args[:4], ('gh', 'release', 'upload', suite.CHANNEL))

    def test_new_snapshot_is_drafted_before_publication(self):
        planned = self.plan()
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'recipe_digest', return_value=self.recipe), \
                patch.object(suite, 'command') as command:
            directory = Path(temporary)
            self.assets(directory, planned)
            self.github.items = [item for item in self.github.items if item['tag_name'] != planned['tag']]
            suite.publish(self.github, planned, directory, 'a' * 40)
            calls = [call.args for call in command.call_args_list]
            self.assertEqual(calls[0][:4], ('gh', 'release', 'create', planned['tag']))
            self.assertIn('--draft', calls[0])
            self.assertEqual(calls[1][:4], ('gh', 'release', 'edit', planned['tag']))
            self.assertIn('--draft=false', calls[1])
            self.assertTrue(all('--latest=false' in call for call in calls))

    def test_interrupted_promotion_keeps_the_old_manifest_so_retry_reuses_snapshot(self):
        previous = self.plan()
        self.github.snapshot(suite.CHANNEL, previous['manifest'])
        self.github.app('computer', '1.2.4')
        planned = self.plan()
        with tempfile.TemporaryDirectory() as temporary, patch.object(suite, 'recipe_digest', return_value=self.recipe):
            directory = Path(temporary)
            self.assets(directory, planned)
            planned['action'] = 'reuse'
            def fail_during_edit(*args):
                if args[:4] == ('gh', 'release', 'edit', suite.CHANNEL):
                    raise RuntimeError('simulated interruption')
            with patch.object(suite, 'command', side_effect=fail_during_edit) as command:
                with self.assertRaisesRegex(RuntimeError, 'simulated interruption'):
                    suite.publish(self.github, planned, directory, 'a' * 40)
                uploads = [call.args for call in command.call_args_list if call.args[2] == 'upload']
                self.assertEqual(len(uploads), 1)
                self.assertNotIn(str(directory / suite.MANIFEST), uploads[0])
            self.assertEqual(self.plan()['action'], 'reuse')
            with patch.object(suite, 'command') as command:
                suite.publish(self.github, planned, directory, 'a' * 40)
                self.assertEqual(command.call_args.args[:5],
                                 ('gh', 'release', 'upload', suite.CHANNEL, str(directory / suite.MANIFEST)))


if __name__ == '__main__':
    unittest.main()
