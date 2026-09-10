import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('image_registry', ROOT / 'scripts/computer-image-registry.py')
registry = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registry)


def labels(version='1.2.3', revision='checked-commit'):
    return {'org.opencontainers.image.version': version,
            'org.opencontainers.image.revision': revision}


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.client = object.__new__(registry.Registry)
        self.client.repo = 'pdparchitect/noodle-computer-shell-image'
        self.client.token = 'anonymous-fixture'

    def test_only_404_means_absent(self):
        for code in [401, 403, 429, 500]:
            with self.subTest(code=code), patch.object(registry, 'urlopen', side_effect=HTTPError('fixture', code, '', {}, None)):
                with self.assertRaises(HTTPError):
                    self.client.get('manifests/1.2.3', missing_ok=True)
        with patch.object(registry, 'urlopen', side_effect=HTTPError('fixture', 404, '', {}, None)):
            self.assertIsNone(self.client.get('manifests/1.2.3', missing_ok=True))
            with self.assertRaises(HTTPError):
                self.client.get('manifests/1.2.3')

    def test_public_manifest_selects_arm64_and_verifies_config(self):
        config = {'os': 'linux', 'architecture': 'arm64', 'config': {'Labels': labels()}}
        manifest = {'config': {'digest': 'sha256:config'}}
        index = {'manifests': [
            {'platform': {'os': 'linux', 'architecture': 'amd64'}, 'digest': 'sha256:amd'},
            {'platform': {'os': 'linux', 'architecture': 'arm64'}, 'digest': 'sha256:arm'},
        ]}
        with patch.object(self.client, 'get', side_effect=[(index, 'sha256:index'), (manifest, 'sha256:arm'), (config, 'sha256:config')]):
            self.assertEqual(self.client.image('latest'), ('sha256:index', 'sha256:config', labels()))
        with patch.object(self.client, 'get', side_effect=[(manifest, 'sha256:manifest'), (config, 'sha256:wrong')]):
            with self.assertRaisesRegex(ValueError, 'checksum'):
                self.client.image('latest')
        config['architecture'] = 'amd64'
        with patch.object(self.client, 'get', side_effect=[(manifest, 'sha256:manifest'), (config, 'sha256:config')]):
            with self.assertRaisesRegex(ValueError, 'ARM64'):
                self.client.image('latest')

    def test_registry_digest_is_computed_from_response(self):
        data = b'{"config": {"digest": "sha256:fixture"}}'
        with patch.object(registry, 'urlopen', return_value=io.BytesIO(data)):
            _, digest = self.client.get('manifests/latest')
        self.assertEqual(digest, 'sha256:' + hashlib.sha256(data).hexdigest())

    def test_mismatched_source_revision_and_version_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'version'):
            registry.verify_labels(labels('1.2.2'), '1.2.3', 'checked-commit')
        with self.assertRaisesRegex(ValueError, 'revision'):
            registry.verify_labels(labels(revision='other-commit'), '1.2.3', 'checked-commit')

    def invoke(self, command, images, local_id='sha256:config'):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'Computer/Images').mkdir(parents=True)
            (root / 'Computer/Images/VERSION').write_text('1.2.3\n')
            local = [{'Id': local_id, 'Config': {'Labels': labels()}}]
            with patch.object(registry, 'ROOT', root), patch.object(registry.sys, 'argv', ['registry', command]), \
                 patch.dict(os.environ, {'GITHUB_SHA': 'checked-commit'}), \
                 patch.object(registry.Registry, '__init__', lambda self, kind: setattr(self, 'repo', kind)), \
                 patch.object(registry.Registry, 'image', side_effect=images), \
                 patch.object(registry.subprocess, 'check_output', return_value=json.dumps(local)), \
                 contextlib.redirect_stdout(io.StringIO()):
                registry.main()

    def test_preflight_rejects_overwrite_and_channel_rollback(self):
        published = ('sha256:manifest', 'sha256:config', labels())
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.invoke('preflight', [published], local_id='sha256:different')
        with self.assertRaisesRegex(ValueError, 'roll back'):
            self.invoke('preflight', [published, ('sha256:new', 'sha256:newconfig', labels('1.3.0'))])
        # Repeating publication of identical tested images is safe.
        self.invoke('preflight', [published, published, published, published])

    def test_channel_requires_both_latest_tags_match_versioned_digests(self):
        published = ('sha256:manifest', 'sha256:config', labels())
        mismatched = ('sha256:different', 'sha256:config', labels())
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.invoke('channel', [published, published, published, mismatched])
        self.invoke('channel', [published, published, published, published])


if __name__ == '__main__':
    unittest.main()
