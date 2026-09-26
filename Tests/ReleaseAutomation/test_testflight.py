"""Hand a released phone build to TestFlight's public group, against a fake App Store Connect."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('testflight', ROOT / 'scripts/testflight.py')
testflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(testflight)

APP = {'id': 'app', 'attributes': {'bundleId': 'com.pdparchitect.noodle.mobile'}}
TESTS_APP = {'id': 'tests', 'attributes': {'bundleId': 'com.pdparchitect.noodle.mobile.tests'}}
GROUPS = [{'id': 'internal', 'attributes': {'name': 'Internal', 'isInternalGroup': True}},
          {'id': 'external', 'attributes': {'name': 'External', 'isInternalGroup': False}}]


class FakeConnect:
    """Answers the calls the handover makes; a build's states advance one poll at a time."""

    def __init__(self, processing=('VALID',), external=('READY_FOR_BETA_SUBMISSION',), builds=True,
                 localizations=(), groups=GROUPS):
        self.processing, self.external = list(processing), list(external)
        self.builds, self.localizations, self.groups = builds, list(localizations), groups
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if path.startswith('/v1/apps?'):
            return {'data': [TESTS_APP, APP]}
        if path.startswith('/v1/builds?'):
            if not self.builds:
                return {'data': []}
            state = self.processing.pop(0) if len(self.processing) > 1 else self.processing[0]
            return {'data': [{'id': 'build', 'attributes': {'processingState': state}}]}
        if path == '/v1/builds/build/buildBetaDetail':
            state = self.external.pop(0) if len(self.external) > 1 else self.external[0]
            return {'data': {'attributes': {'externalBuildState': state}}}
        if path == '/v1/builds/build/betaBuildLocalizations':
            return {'data': self.localizations}
        if path.startswith('/v1/betaGroups?'):
            return {'data': self.groups}
        if method in ('POST', 'PATCH'):
            return {}
        raise AssertionError(f'Unexpected call {method} {path}')

    def writes(self):
        return [(method, path) for method, path, _ in self.calls if method != 'GET']


def run(connect, wait=True, notes='- Something new.\n', released=True):
    testflight.hand_over(connect, version='0.2.0', notes=notes, released=released, wait=wait,
                         sleep=lambda seconds: None, clock=iter(range(0, 100000, 60)).__next__)


class NotesTests(unittest.TestCase):
    def test_whole_section_becomes_plain_text(self):
        notes = ('### Added\n\n- Chat with **bots** on the [Hub](https://example.invalid).\n'
                 '- Send `photos`.\n\n### Fixed\n\n- A crash.\n')
        self.assertEqual(testflight.what_to_test(notes),
                         'Added\n\n• Chat with bots on the Hub.\n• Send photos.\n\nFixed\n\n• A crash.')

    def test_what_to_test_heading_is_used_alone(self):
        notes = ('### What to Test\n\n- Open a shared browser.\n- Join a second Hub.\n\n'
                 '### Added\n\n- Everything else.\n')
        self.assertEqual(testflight.what_to_test(notes), '• Open a shared browser.\n• Join a second Hub.')

    def test_long_notes_end_at_a_line_within_apples_limit(self):
        notes = ''.join(f'- Change number {n} with some words to make it longer.\n' for n in range(200))
        text = testflight.what_to_test(notes)
        self.assertLessEqual(len(text), 4000)
        self.assertTrue(text.endswith('longer.\n…'))


class HandOverTests(unittest.TestCase):
    def test_new_build_waits_then_gets_notes_joins_external_and_is_submitted(self):
        connect = FakeConnect(processing=['PROCESSING', 'PROCESSING', 'VALID'],
                              external=['PROCESSING', 'READY_FOR_BETA_SUBMISSION'])
        run(connect)
        self.assertEqual(connect.writes(), [
            ('POST', '/v1/betaBuildLocalizations'),
            ('POST', '/v1/betaGroups/external/relationships/builds'),
            ('POST', '/v1/betaAppReviewSubmissions')])
        localization = connect.calls[[c[1] for c in connect.calls].index('/v1/betaBuildLocalizations')][2]
        self.assertEqual(localization['data']['attributes'], {'locale': 'en-US', 'whatsNew': '• Something new.'})
        self.assertEqual(localization['data']['relationships']['build']['data'], {'type': 'builds', 'id': 'build'})
        builds = next(path for _, path, _ in connect.calls if path.startswith('/v1/builds?'))
        self.assertIn('filter[app]=app', builds)
        self.assertIn('filter[preReleaseVersion.version]=0.2.0', builds)

    def test_a_retry_updates_notes_but_does_not_submit_again(self):
        for state in ['WAITING_FOR_BETA_REVIEW', 'IN_BETA_REVIEW', 'BETA_APPROVED', 'IN_BETA_TESTING']:
            with self.subTest(state=state):
                connect = FakeConnect(external=[state],
                                      localizations=[{'id': 'loc', 'attributes': {'locale': 'en-US'}}])
                run(connect)
                self.assertEqual(connect.writes(), [
                    ('PATCH', '/v1/betaBuildLocalizations/loc'),
                    ('POST', '/v1/betaGroups/external/relationships/builds')])

    def test_unreleased_version_is_left_alone(self):
        connect = FakeConnect()
        run(connect, released=False)
        self.assertEqual(connect.calls, [])

    def test_missing_build_is_only_awaited_right_after_an_upload(self):
        connect = FakeConnect(builds=False)
        run(connect, wait=False)
        self.assertEqual(connect.writes(), [])
        with self.assertRaisesRegex(RuntimeError, 'did not appear'):
            run(FakeConnect(builds=False), wait=True)

    def test_problems_apple_reports_stop_the_handover(self):
        for state, message in [('MISSING_EXPORT_COMPLIANCE', 'export compliance'), ('BETA_REJECTED', 'rejected')]:
            with self.subTest(state=state):
                connect = FakeConnect(external=[state])
                with self.assertRaisesRegex(RuntimeError, message):
                    run(connect)
                self.assertNotIn(('POST', '/v1/betaAppReviewSubmissions'), connect.writes())
        with self.assertRaisesRegex(RuntimeError, 'processing failed'):
            run(FakeConnect(processing=['FAILED']))

    def test_the_public_group_must_exist(self):
        with self.assertRaisesRegex(RuntimeError, 'External'):
            run(FakeConnect(groups=GROUPS[:1]))


class ReleaseStateTests(unittest.TestCase):
    def test_only_a_version_tagged_on_this_commit_was_just_uploaded(self):
        with tempfile.TemporaryDirectory() as folder:
            git = lambda *args: subprocess.run(['git', '-C', folder, *args], check=True, capture_output=True)
            git('init')
            git('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '--allow-empty', '-m', 'one')
            self.assertEqual(testflight.release_state(folder, 'mobile-v0.2.0'), (False, False))
            git('tag', 'mobile-v0.2.0')
            self.assertEqual(testflight.release_state(folder, 'mobile-v0.2.0'), (True, True))
            git('-c', 'user.name=t', '-c', 'user.email=t@example.invalid', 'commit', '--allow-empty', '-m', 'two')
            self.assertEqual(testflight.release_state(folder, 'mobile-v0.2.0'), (True, False))


class TokenTests(unittest.TestCase):
    def test_token_is_an_es256_jwt_for_app_store_connect(self):
        with tempfile.TemporaryDirectory() as folder:
            key = Path(folder) / 'key.p8'
            pem = subprocess.run('openssl ecparam -genkey -name prime256v1 | openssl pkcs8 -topk8 -nocrypt',
                                 shell=True, check=True, capture_output=True).stdout
            key.write_bytes(pem)
            token = testflight.token(key, 'KEY', 'ISSUER', now=1000)
        decode = lambda part: base64.urlsafe_b64decode(part + '=' * (-len(part) % 4))
        header, payload, signature = token.split('.')
        self.assertEqual(json.loads(decode(header)), {'alg': 'ES256', 'kid': 'KEY', 'typ': 'JWT'})
        self.assertEqual(json.loads(decode(payload)),
                         {'iss': 'ISSUER', 'iat': 1000, 'exp': 2200, 'aud': 'appstoreconnect-v1'})
        self.assertEqual(len(decode(signature)), 64)


if __name__ == '__main__':
    unittest.main()
