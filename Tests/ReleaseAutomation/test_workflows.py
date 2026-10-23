"""Exercise the real workflow dependency conditions, without GitHub or secrets."""
import itertools
import fnmatch
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def workflow(name):
    # macOS ships Ruby/Psych; no package installation is needed by these checks.
    return json.loads(subprocess.check_output([
        'ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.load_file(ARGV[0]))',
        str(ROOT / '.github/workflows' / name)], text=True))


def condition(text, values):
    text = text.replace('always()', 'True').replace('!cancelled()', 'True')
    for name in sorted(values, key=len, reverse=True):
        text = text.replace(name, repr(values[name]))
    text = text.replace('&&', ' and ').replace('||', ' or ')
    if re.search(r'\b(needs|github)\.', text):
        raise AssertionError('Unbound workflow context: ' + text)
    return eval('(' + text + ')', {'__builtins__': {}}, {})


def matches_paths(paths, patterns):
    # These workflow filters use only ** globs (which match across directories).
    # Evaluate ordered exclusions/re-inclusions, then GitHub's any-file rule.
    for path in paths:
        included = False
        for pattern in patterns:
            if fnmatch.fnmatchcase(path, pattern.removeprefix('!')):
                included = not pattern.startswith('!')
        if included:
            return True
    return False


class WorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.flow = workflow('release.yml')
        cls.jobs = cls.flow['jobs']

    def base(self):
        return {
            'github.event_name': 'push', 'github.ref': 'refs/heads/main',
            'needs.versions.outputs.any': 'true', 'needs.checks.result': 'success',
            'needs.workflow-lint.result': 'success',
            'needs.test-noodle-macos27.result': 'success',
            **{f'needs.test-{p}.result': 'success' for p in ['noodle', 'shared', 'computer', 'applet', 'applet-rendering', 'browser', 'mail', 'hub', 'mobile', 'bridge']},
            **{f'needs.versions.outputs.{p}': 'true' for p in ['noodle', 'computer', 'applet', 'browser', 'hub', 'mobile', 'images']},
            **{f'needs.prepare-{p}.result': 'success' for p in ['noodle', 'computer', 'applet', 'browser', 'hub', 'mobile', 'images']},
        }

    def test_tag_gate_blocks_failed_cancelled_or_skipped_selected_products(self):
        gate = self.jobs['tag']['if']
        for selected in itertools.product([False, True], repeat=7):
            if not any(selected):
                continue
            values = self.base()
            for product, active in zip(['noodle', 'computer', 'applet', 'browser', 'hub', 'mobile', 'images'], selected):
                values[f'needs.versions.outputs.{product}'] = str(active).lower()
                values[f'needs.prepare-{product}.result'] = 'success' if active else 'skipped'
            self.assertTrue(condition(gate, values))
            for product, active in zip(['noodle', 'computer', 'applet', 'browser', 'hub', 'mobile', 'images'], selected):
                if active:
                    for failure in ['failure', 'cancelled', 'skipped']:
                        self.assertFalse(condition(gate, {**values, f'needs.prepare-{product}.result': failure}))
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(condition(gate, {**self.base(), 'needs.checks.result': result}))
            self.assertFalse(condition(gate, {**self.base(), 'needs.workflow-lint.result': result}))

    def test_preparation_and_tests_start_without_waiting_for_each_other(self):
        # Signing runs alongside the tests; only the tag gate below needs them.
        for name, job in self.jobs.items():
            needs = job.get('needs', [])
            if name.startswith('prepare-'):
                self.assertFalse([n for n in needs if n.startswith('test-')], name)
            if name.startswith('test-'):
                self.assertNotIn('checks', needs, name)

    def test_every_package_the_workflows_test_has_tests(self):
        # swift test fails a package without test targets, as when its tests move elsewhere.
        for path in sorted((ROOT / '.github/workflows').glob('*.yml')):
            for package in re.findall(r'swift test\b[^\n]*--package-path (\S+)', path.read_text()):
                self.assertIn('.testTarget(', (ROOT / package / 'Package.swift').read_text(), f'{path.name}: {package}')

    def test_release_archives_build_apple_silicon_only(self):
        # Package dependencies ignore the app targets' ARCHS; only the command line reaches them.
        script = (ROOT / 'scripts/package-xcode-release.sh').read_text()
        archive = script[script.index('xcodebuild -workspace'):script.index(' archive >&2')]
        self.assertIn(' ARCHS=arm64 ', archive)

    def test_pr_other_branch_and_no_version_change_never_tag(self):
        for changes in [
            {'github.event_name': 'pull_request'},
            {'github.ref': 'refs/heads/feature'},
            {'needs.versions.outputs.any': 'false'},
        ]:
            self.assertFalse(condition(self.jobs['tag']['if'], {**self.base(), **changes}))

    def test_publication_requires_tags_and_image_success(self):
        images = self.jobs['publish-images']
        # Explicit status handling is needed even when a direct dependency
        # succeeded: skipped preparation ancestors propagate through success().
        self.assertIn('always()', images['if'])
        self.assertTrue(condition(images['if'], {
            **self.base(), 'needs.tag.result': 'success'}))
        self.assertFalse(condition(images['if'], {
            **self.base(), 'needs.tag.result': 'failure'}))
        computer = self.jobs['publish-computer']
        values = {**self.base(), 'needs.tag.result': 'success', 'needs.publish-images.result': 'success'}
        self.assertTrue(condition(computer['if'], values))
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(condition(computer['if'], {**values, 'needs.tag.result': result}))
            self.assertFalse(condition(computer['if'], {**values, 'needs.publish-images.result': result}))
        self.assertTrue(condition(computer['if'], {
            **values, 'needs.versions.outputs.images': 'false', 'needs.publish-images.result': 'skipped'}))
        noodle = self.jobs['publish-noodle']
        values['needs.publish-computer.result'] = 'success'
        values['needs.publish-applet.result'] = 'success'
        values['needs.publish-browser.result'] = 'success'
        self.assertTrue(condition(noodle['if'], values))
        self.assertFalse(condition(noodle['if'], {**values, 'needs.publish-computer.result': 'failure'}))
        self.assertFalse(condition(noodle['if'], {**values, 'needs.publish-applet.result': 'failure'}))
        self.assertFalse(condition(noodle['if'], {**values, 'needs.publish-browser.result': 'failure'}))
        browser = self.jobs['publish-browser']
        self.assertTrue(condition(browser['if'], values))
        self.assertFalse(condition(browser['if'], {**values, 'needs.tag.result': 'failure'}))
        applet = self.jobs['publish-applet']
        self.assertTrue(condition(applet['if'], values))
        self.assertFalse(condition(applet['if'], {**values, 'needs.tag.result': 'failure'}))
        mobile = self.jobs['publish-mobile']
        self.assertTrue(condition(mobile['if'], values))
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(condition(mobile['if'], {**values, 'needs.tag.result': result}))
        self.assertFalse(condition(mobile['if'], {**values, 'needs.versions.outputs.mobile': 'false'}))

    def test_suites_run_independently_of_version_changes(self):
        # Only scripts/ci-scope.py's suites decide whether a suite runs; it runs them all for a release. Release
        # selection still gates preparation/publication, but never suppresses a suite.
        for product in ['noodle', 'shared', 'computer', 'applet', 'browser', 'hub', 'mobile', 'bridge']:
            job = self.jobs['test-' + product]
            self.assertEqual(job['if'], f"contains(fromJSON(needs.versions.outputs.suites), '{product}')")
            self.assertEqual(job['needs'], ['versions'])
            # The phone app uses iOS 27 APIs and Windows computers use macOS 27's custom Virtio
            # devices, which only the Xcode 27 image's SDK has.
            self.assertEqual(job['runs-on'], 'xcode-27' if product in ['mobile', 'computer'] else 'macos-26')
        self.assertEqual(workflow('mobile-release.yml')['jobs']['release']['runs-on'], 'xcode-27')
        # The Xcode 27 image ships without the Metal toolchain that Computer's SwiftTerm shaders need.
        for job in [self.jobs['test-computer'], workflow('computer-release.yml')['jobs']['release']]:
            self.assertEqual(job['runs-on'], 'xcode-27')
            self.assertIn('xcodebuild -downloadComponent MetalToolchain', json.dumps(job['steps']))
        self.assertNotIn('test-computer', self.jobs['prepare-noodle']['needs'])
        self.assertEqual(self.jobs['prepare-images']['needs'], ['versions', 'checks'])
        self.assertNotIn('swift test', json.dumps(self.jobs['checks']))

    def test_sandbox_helpers_are_built_before_the_suite(self):
        steps = self.jobs['test-noodle']['steps']
        fixture = next(i for i, step in enumerate(steps)
                       if 'Tests/build-sandbox-cli-fixture.sh' in step.get('run', ''))
        suite = next(i for i, step in enumerate(steps) if step.get('id') == 'tests')
        self.assertLess(fixture, suite)
        for index in [fixture, suite]:
            self.assertFalse(steps[index].get('continue-on-error', False))
            self.assertNotIn('if', steps[index])
        self.assertEqual(steps[suite]['env']['NOODLE_TEST_CLI_APPLICATION'],
                         '${{ github.workspace }}/.build/Sandbox CLI Tests.app')

    def test_apple27_harness_always_runs_on_the_release_image(self):
        job = self.jobs['test-noodle-macos27']
        self.assertEqual(job['runs-on'], 'xcode-27')
        # Like every suite it runs for every release and is skipped only where scripts/ci-scope.py says.
        self.assertEqual(job['if'], "contains(fromJSON(needs.versions.outputs.suites), 'noodle-macos27')")
        tests = next(step for step in job['steps'] if "--filter 'AppleLocalModelsTests" in step.get('run', ''))
        for step in job['steps']:
            self.assertNotIn('if', step)
            self.assertFalse(step.get('continue-on-error', False))
        self.assertFalse(job.get('continue-on-error', False))
        self.assertIn('set -euo pipefail', tests['run'])
        self.assertIn('localModelsSupported', tests['run'])
        self.assertIn('build-mlx-metal.sh', tests['run'])
        self.assertEqual(tests['env']['NOODLE_APPLE_HARNESS_ONLY'], '1')
    def test_selected_test_failures_block_tagging(self):
        # Preparation does not wait for the tests, so this gate is all that keeps a failed suite from shipping.
        tests = [name for name in self.jobs if name.startswith('test-')]
        self.assertIn('test-shared', tests)
        for name in tests:
            self.assertIn(name, self.jobs['tag']['needs'])
            for result in ['failure', 'cancelled', 'skipped']:
                self.assertFalse(condition(self.jobs['tag']['if'], {
                    **self.base(), f'needs.{name}.result': result}), name)
        # A Hub-only release still requires Noodle's tests: the Hub ships Noodle's runtime.
        hub_only = {**self.base(), **{f'needs.versions.outputs.{p}': 'false' for p in ['noodle', 'computer', 'applet', 'browser', 'mobile', 'images']}}
        self.assertTrue(condition(self.jobs['tag']['if'], hub_only))
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(condition(self.jobs['tag']['if'], {**hub_only, 'needs.test-noodle.result': result}))
        # The phone app shares no code with Noodle, so a Mobile-only release does not wait for its tests.
        mobile_only = {**self.base(), **{f'needs.versions.outputs.{p}': 'false' for p in ['noodle', 'computer', 'applet', 'browser', 'hub', 'images']}}
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertTrue(condition(self.jobs['tag']['if'], {**mobile_only, 'needs.test-noodle.result': result}))
        # A Noodle-only release accepts skipped Computer tests and preparation.
        self.assertTrue(condition(self.jobs['tag']['if'], {
            **self.base(), 'needs.versions.outputs.computer': 'false',
            'needs.test-computer.result': 'skipped', 'needs.prepare-computer.result': 'skipped'}))

    def test_noodle_release_checks_sdk_and_metal_before_signing(self):
        job = workflow('prepare-noodle-release.yml')['jobs']['release']
        self.assertEqual(job['runs-on'], 'xcode-27')
        steps = job['steps']
        prerequisite = next(i for i, step in enumerate(steps) if 'sdk_version=' in step.get('run', ''))
        signing = next(i for i, step in enumerate(steps) if 'MACOS_CERTIFICATE_P12' in step.get('env', {}))
        self.assertLess(prerequisite, signing)
        package = next(i for i, step in enumerate(steps) if 'scripts/package-xcode-release.sh Noodle' in step.get('run', ''))
        self.assertLess(signing, package)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name, body in {
                'xcrun': 'printf "%s\\n" "$FIXTURE_SDK"',
                'xcodebuild': 'printf "%s\\n" "$*" > "$FIXTURE_METAL_LOG"; exit "$FIXTURE_METAL_STATUS"',
            }.items():
                path = root / name
                path.write_text('#!/bin/sh\n' + body + '\n')
                path.chmod(0o700)
            for sdk, metal_status, succeeds in [('26.5', '0', False), ('27.0', '0', True), ('27.0', '1', False)]:
                with self.subTest(sdk=sdk, metal_status=metal_status):
                    log = root / 'metal.log'
                    log.unlink(missing_ok=True)
                    result = subprocess.run(['/bin/zsh', '-c', steps[prerequisite]['run']],
                        env=dict(os.environ, PATH=f'{root}:/usr/bin:/bin', FIXTURE_SDK=sdk,
                                 FIXTURE_METAL_STATUS=metal_status, FIXTURE_METAL_LOG=str(log)),
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                    if sdk == '26.5':
                        self.assertFalse(log.exists())
                    else:
                        self.assertEqual(log.read_text().strip(), '-downloadComponent MetalToolchain')

    def test_incomplete_publication_cannot_report_release_success(self):
        complete = self.jobs['complete']
        self.assertIn('always()', complete['if'])
        step = complete['steps'][0]
        source = step['run'].split("\n", 1)[1].rsplit("\nPY", 1)[0]
        for selected in [['noodle'], ['computer', 'images'], ['applet'], ['browser'], ['hub'], ['mobile'], ['noodle', 'applet', 'browser', 'hub', 'mobile'], ['images']]:
            environment = {**os.environ, 'RELEASE_PRODUCTS': json.dumps(selected),
                           **{p.upper() + '_RESULT': 'success' if p in selected else 'skipped'
                              for p in ['noodle', 'computer', 'applet', 'browser', 'hub', 'mobile', 'images']}}
            passed = subprocess.run(['python3', '-c', source], env=environment, capture_output=True)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            for product in selected:
                for failure in ['skipped', 'failure', 'cancelled']:
                    failed = subprocess.run(['python3', '-c', source], env={
                        **environment, product.upper() + '_RESULT': failure}, capture_output=True)
                    self.assertNotEqual(failed.returncode, 0)

    def test_testflight_handover_follows_only_complete_trusted_releases(self):
        # Its own workflow, so waiting for Apple or failing there never holds back the Suite.
        self.assertNotIn('testflight-mobile', self.jobs)
        flow = workflow('testflight.yml')
        triggers = flow.get('on', flow.get('true'))
        self.assertEqual(triggers['workflow_run']['workflows'],
                         ['Validate and release versions', 'Publish verified release artifacts'])
        self.assertEqual(triggers['workflow_run']['types'], ['completed'])
        self.assertEqual(flow['permissions'], {'contents': 'read'})
        self.assertFalse(flow['concurrency']['cancel-in-progress'])
        job = flow['jobs']['external']
        values = {'github.ref': 'refs/heads/main', 'github.event_name': 'workflow_run',
                  'github.repository': 'pdparchitect/noodle',
                  'github.event.workflow_run.conclusion': 'success',
                  'github.event.workflow_run.head_branch': 'main',
                  'github.event.workflow_run.head_repository.full_name': 'pdparchitect/noodle',
                  'github.event.workflow_run.event': 'push'}
        self.assertTrue(condition(job['if'], values))
        self.assertTrue(condition(job['if'], {**values, 'github.event_name': 'workflow_dispatch'}))
        for changes in [
            {'github.ref': 'refs/heads/feature'},
            {'github.event.workflow_run.conclusion': 'failure'},
            {'github.event.workflow_run.conclusion': 'cancelled'},
            {'github.event.workflow_run.head_branch': 'feature'},
            {'github.event.workflow_run.head_repository.full_name': 'someone/noodle'},
            {'github.event.workflow_run.event': 'pull_request'},
        ]:
            self.assertFalse(condition(job['if'], {**values, **changes}))
        checkout = job['steps'][0]
        self.assertEqual(checkout['with']['fetch-depth'], 0)
        self.assertIn('github.event.workflow_run.head_sha', checkout['with']['ref'])
        self.assertIn('python3 scripts/testflight.py', json.dumps(job))

    def test_preparation_is_read_only_and_publication_uses_artifacts(self):
        for name in ['prepare-noodle-release.yml', 'computer-release.yml', 'applet-release.yml', 'browser-release.yml', 'hub-release.yml', 'mobile-release.yml', 'computer-images.yml']:
            prepare = workflow(name)
            self.assertEqual(prepare['permissions'], {'contents': 'read'})
            rendered = json.dumps(prepare)
            for write in ['gh release create', 'docker push', 'git push']:
                self.assertNotIn(write, rendered)
            self.assertIn('actions/upload-artifact@v6', rendered)
        for job in ['publish-noodle', 'publish-computer', 'publish-applet', 'publish-browser', 'publish-hub', 'publish-mobile', 'publish-images']:
            self.assertIn('tag', self.jobs[job]['needs'])
            self.assertIn('actions/download-artifact@v7', json.dumps(self.jobs[job]))

    def test_noodle_publishes_fixed_name_assets_only_after_checksum_verification(self):
        publish = next(step['run'] for step in self.jobs['publish-noodle']['steps']
                       if 'gh release create' in step.get('run', ''))
        for scenario in ['valid', 'corrupt', 'corrupt-dmg', 'missing-dmg', 'existing']:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'dist').mkdir()
                (root / 'bin').mkdir()
                (root / 'VERSION').write_text('1.2.3\n')
                archive = 'Noodle-arm64.zip'
                (root / 'dist' / archive).write_bytes(b'prepared archive')
                digest = hashlib.sha256(b'prepared archive').hexdigest()
                (root / 'dist' / (archive + '.sha256')).write_text(f'{digest}  {archive}\n')
                disk_image = 'Noodle-arm64.dmg'
                (root / 'dist' / disk_image).write_bytes(b'prepared archive')
                (root / 'dist' / (disk_image + '.sha256')).write_text(f'{digest}  {disk_image}\n')
                for name in ['appcast.xml', 'release-notes.md']:
                    (root / 'dist' / name).write_text('fixture')
                if scenario == 'corrupt':
                    (root / 'dist' / archive).write_bytes(b'modified archive')
                if scenario == 'corrupt-dmg':
                    (root / 'dist' / disk_image).write_bytes(b'modified disk image')
                if scenario == 'missing-dmg':
                    (root / 'dist' / disk_image).unlink()
                gh = root / 'bin' / 'gh'
                gh.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_GH_LOG"\n'
                              'if [ "$1 $2" = "release view" ]; then exit "$TEST_RELEASE_EXISTS"; fi\n')
                gh.chmod(0o700)
                log = root / 'commands.log'
                log.touch()
                result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', publish], cwd=root,
                    env={**os.environ, 'PATH': str(root / 'bin') + os.pathsep + os.environ['PATH'],
                         'TEST_GH_LOG': str(log), 'TEST_RELEASE_EXISTS': '0' if scenario == 'existing' else '1'},
                    capture_output=True, text=True)
                commands = log.read_text()
                if scenario == 'valid':
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('release create v1.2.3 dist/Noodle-arm64.zip dist/Noodle-arm64.zip.sha256 dist/appcast.xml', commands)
                    self.assertIn('dist/Noodle-arm64.dmg dist/Noodle-arm64.dmg.sha256', commands)
                    self.assertIn('--draft --verify-tag', commands)
                    self.assertIn('release edit v1.2.3 --draft=false --latest', commands)
                    self.assertNotIn('--clobber', commands)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotIn('release create', commands)
                    self.assertNotIn('release edit', commands)

    def test_computer_packaging_has_guest_helper_toolchain(self):
        steps = workflow('computer-release.yml')['jobs']['release']['steps']
        setup = next(i for i, step in enumerate(steps)
                     if step.get('uses', '').startswith('actions/setup-go@'))
        package = next(i for i, step in enumerate(steps)
                       if 'scripts/package-xcode-release.sh Computer' in step.get('run', ''))
        self.assertLess(setup, package)
        self.assertEqual(steps[setup]['with']['go-version'], '1.26.x')
        # The helper builds directly from standard-library-only source, without go.mod.
        self.assertFalse(steps[setup]['with']['cache'])

    def test_file_versions_drive_main_push_without_tag_event_recursion(self):
        # YAML 1.1 interprets the key "on" as true.
        triggers = self.flow.get('on', self.flow.get('true'))
        self.assertEqual(triggers['push']['branches'], ['main'])
        self.assertNotIn('tags', triggers['push'])
        self.assertIn('workflow_dispatch', triggers)
        for name in ['prepare-noodle-release.yml', 'computer-release.yml', 'applet-release.yml', 'browser-release.yml', 'hub-release.yml', 'mobile-release.yml', 'computer-images.yml']:
            child = workflow(name)
            self.assertNotIn('push', child.get('on', child.get('true')))
        self.assertEqual(self.jobs['tag']['needs'], [
            'versions', 'workflow-lint', 'checks', 'test-noodle', 'test-shared', 'test-noodle-macos27', 'test-computer', 'test-applet', 'test-applet-rendering', 'test-browser', 'test-mail', 'test-hub', 'test-mobile', 'test-bridge',
            'prepare-noodle', 'prepare-computer', 'prepare-applet', 'prepare-browser', 'prepare-hub', 'prepare-mobile', 'prepare-images'])

    def test_documentation_only_changes_skip_app_ci_but_release_inputs_do_not(self):
        triggers = self.flow.get('on', self.flow.get('true'))
        docs = ['README.md', 'AGENTS.md', '.github/pull_request_template.md',
                'Computer/README.md', 'Computer/Bridge/README.md',
                'Computer/Images/README.md', 'Applet/RELEASING.md', 'Browser/README.md', 'Browser/RELEASING.md',
                'Hub/README.md', 'Hub/RELEASING.md', 'Mobile/README.md',
                'docs/releases.md', 'docs/example-diagram.svg',
                'docs/example-diagram.json', 'website/index.html',
                'website/assets/noodle.png',
                'CHANGELOG.md', 'Computer/CHANGELOG.md', 'Applet/CHANGELOG.md', 'Browser/CHANGELOG.md', 'Hub/CHANGELOG.md',
                'Mobile/CHANGELOG.md', 'Computer/Images/CHANGELOG.md']
        required = ['VERSION', 'Computer/VERSION', 'Applet/VERSION', 'Browser/VERSION', 'Hub/VERSION', 'Mobile/VERSION', 'Computer/Images/VERSION',
                    'Sources/NoodleCore/MessengerDocumentation.swift', 'Package.swift',
                    'Tests/NoodleAppTests/ScreenCaptureTests.swift', 'Project.swift',
                    'Support/AppIcon.png', 'Support/update-milestones.json',
                    'Computer/Images/desktop/Dockerfile', 'Applet/Support/Info.plist', 'Hub/Support/Info.plist', 'Mobile/Project.swift',
                    '.github/workflows/release.yml']
        for event in ['push', 'pull_request']:
            patterns = triggers[event]['paths']
            self.assertFalse(matches_paths(docs, patterns), event)
            for path in required:
                with self.subTest(event=event, path=path):
                    self.assertTrue(matches_paths([path], patterns))
                    self.assertTrue(matches_paths(docs + [path], patterns))

    def test_image_docs_skip_builds_but_image_changes_and_releases_still_run(self):
        flow = workflow('computer-images.yml')
        triggers = flow.get('on', flow.get('true'))
        patterns = triggers['pull_request']['paths']
        docs = ['README.md', 'Computer/Images/README.md']
        self.assertFalse(matches_paths(docs, patterns))
        self.assertIn('workflow_call', triggers)
        for path in ['Computer/Images/VERSION', 'Computer/Images/CHANGELOG.md',
                     'Computer/Images/desktop/Dockerfile', 'Computer/Images/shared/verify.sh',
                     'Computer/Images/tests/desktop.sh',
                     'Computer/Images/desktop/overlay/usr/share/backgrounds/desktop-wallpaper.png',
                     '.github/workflows/computer-images.yml']:
            with self.subTest(path=path):
                self.assertTrue(matches_paths(docs + [path], patterns))

    def test_suite_only_runs_for_successful_trusted_main_releases(self):
        flow = workflow('suite-release.yml')
        triggers = flow.get('on', flow.get('true'))
        self.assertEqual(triggers['workflow_run']['workflows'],
                         ['Validate and release versions', 'Publish verified release artifacts'])
        values = {'github.ref': 'refs/heads/main', 'github.event_name': 'workflow_run',
                  'github.repository': 'pdparchitect/noodle',
                  'github.event.workflow_run.conclusion': 'success',
                  'github.event.workflow_run.head_branch': 'main',
                  'github.event.workflow_run.head_repository.full_name': 'pdparchitect/noodle',
                  'github.event.workflow_run.event': 'push'}
        gate = flow['jobs']['plan']['if']
        self.assertTrue(condition(gate, values))
        self.assertTrue(condition(gate, {**values, 'github.event_name': 'workflow_dispatch'}))
        for changes in [
            {'github.ref': 'refs/heads/feature'},
            {'github.event.workflow_run.conclusion': 'failure'},
            {'github.event.workflow_run.head_branch': 'feature'},
            {'github.event.workflow_run.head_repository.full_name': 'someone/noodle'},
            {'github.event.workflow_run.event': 'pull_request'},
        ]:
            self.assertFalse(condition(gate, {**values, **changes}))
        self.assertFalse(flow['concurrency']['cancel-in-progress'])

    def test_suite_noop_skips_macos_and_reuse_skips_signing_and_packaging(self):
        flow = workflow('suite-release.yml')
        assemble = flow['jobs']['assemble']
        steps = assemble['steps']
        for action in ['none', 'reuse', 'build']:
            values = {'needs.plan.outputs.action': action}
            self.assertEqual(condition(assemble['if'], values), action != 'none')
            for step in steps:
                if 'MACOS_CERTIFICATE_P12' in step.get('env', {}) or 'package-dmg.sh' in step.get('run', ''):
                    self.assertEqual(condition(step['if'], values), action == 'build')
        rendered = json.dumps(flow)
        for compiler in ['swift build', 'build-app.sh', 'package-release.sh']:
            self.assertNotIn(compiler, rendered)
        self.assertIn('actions/cache/restore@v5', rendered)
        self.assertIn('actions/cache/save@v5', rendered)
        retained = next(i for i, step in enumerate(steps) if step.get('with', {}).get('name') == 'suite-release-assets')
        published = next(i for i, step in enumerate(steps) if 'suite-release.py publish' in step.get('run', ''))
        self.assertLess(retained, published)

    def test_push_deploys_from_main_only_after_its_tests(self):
        flow = workflow('push.yml')
        triggers = flow.get('on', flow.get('true'))
        self.assertEqual(triggers['push']['branches'], ['main'])
        self.assertIn('workflow_dispatch', triggers)
        for event in ['push', 'pull_request']:
            patterns = triggers[event]['paths']
            for path in ['Push/Package.swift', 'Push/Sources/PushCore/PushService.swift', 'Push/Dockerfile',
                         'Push/worker/wrangler.toml', 'Push/worker/src/index.ts', '.github/workflows/push.yml']:
                self.assertTrue(matches_paths([path], patterns), f'{event}: {path}')
            self.assertFalse(matches_paths(['Push/CHANGELOG.md', 'Sources/HubCore/HubBots.swift'], patterns), event)
        jobs = flow['jobs']
        deploy = jobs['deploy']
        self.assertEqual(deploy['environment'], 'push-production')
        self.assertEqual(deploy['needs'], ['test-linux', 'worker', 'image'])
        for event, ref, deploys in [('push', 'refs/heads/main', True), ('workflow_dispatch', 'refs/heads/main', True),
                                    ('pull_request', 'refs/heads/main', False), ('workflow_dispatch', 'refs/heads/feature', False)]:
            self.assertEqual(condition(deploy['if'], {'github.event_name': event, 'github.ref': ref}), deploys, (event, ref))
        # Only the deploy job sees secrets, and it hands the app's to wrangler in a file, not on a command line.
        for name, job in jobs.items():
            if name != 'deploy':
                self.assertNotIn('secrets.', json.dumps(job), name)
        step = next(step for step in deploy['steps'] if 'wrangler deploy' in step.get('run', ''))
        self.assertIn('npx wrangler deploy --secrets-file "$secrets"', step['run'])
        self.assertIn('umask 077', step['run'])
        self.assertEqual(sorted(step['env']), ['APNS_KEY_ID', 'APNS_KEY_P8', 'CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_API_TOKEN', 'PUSH_SEAL_KEY'])
        self.assertIn('swift test --disable-sandbox --package-path Push ', json.dumps(self.jobs['test-shared']))

    def test_push_pins_what_it_runs_and_reads_only(self):
        flow = workflow('push.yml')
        self.assertEqual(flow['permissions'], {'contents': 'read'})
        for name, job in flow['jobs'].items():
            self.assertNotIn('permissions', job, name)
            for step in job['steps']:
                if 'uses' in step:
                    self.assertRegex(step['uses'], r'^[\w.-]+/[\w.-]+@[0-9a-f]{40}$', name)
                if step.get('uses', '').startswith('actions/checkout@'):
                    self.assertIs(step['with']['persist-credentials'], False, name)
        self.assertRegex(flow['jobs']['test-linux']['container'], r'^swift:6\.4\.1-noble@sha256:[0-9a-f]{64}$')
        dockerfile = (ROOT / 'Push' / 'Dockerfile').read_text()
        bases = re.findall(r'^FROM (?:--platform=\S+ )?(\S+)', dockerfile, re.MULTILINE)
        self.assertEqual(len(bases), 2)
        for base in bases:
            self.assertRegex(base, r'@sha256:[0-9a-f]{64}$')
        self.assertIn(flow['jobs']['test-linux']['container'], bases, 'CI tests on the toolchain the image builds with')
        self.assertIn('--force-resolved-versions', dockerfile)

def ci_scope(root=ROOT):
    spec = importlib.util.spec_from_file_location('ci_scope', root / 'scripts/ci-scope.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def suite_gate(text, suites):
    # The one expression the suite gates use, after any plain conditions in front of it.
    match = re.fullmatch(r"(?:(.*) && )?contains\(fromJSON\(needs\.versions\.outputs\.suites\), '([\w-]+)'\)", text)
    return match[2] in suites, match[1]


class ScopeGateTests(unittest.TestCase):
    """How the versions job's suites decide which test jobs take a runner."""
    @classmethod
    def setUpClass(cls):
        cls.scope = ci_scope()
        cls.jobs = workflow('release.yml')['jobs']

    def test_every_test_job_and_the_checks_run_only_for_their_own_suite(self):
        gated = sorted(name for name in self.jobs if name.startswith('test-')) + ['checks']
        self.assertEqual(sorted(self.scope.EVERYTHING), sorted(name.removeprefix('test-') for name in gated))
        for name in gated:
            suite = name.removeprefix('test-')
            self.assertEqual(suite_gate(self.jobs[name]['if'], [suite])[0], True, name)
            self.assertEqual(suite_gate(self.jobs[name]['if'], [s for s in self.scope.EVERYTHING if s != suite])[0], False)
            # A suite that does not run is skipped, which "CI passed" accepts and the tag gate never does.
            self.assertIn(name, self.jobs['tag']['needs'])
            if name != 'test-applet-rendering':
                self.assertIn(name, self.jobs['ci-passed']['needs'])
        self.assertEqual(suite_gate(self.jobs['test-applet-rendering']['if'], [])[1],
                         "github.event_name != 'pull_request' && github.ref == 'refs/heads/main'")
        versions = self.jobs['versions']
        self.assertEqual(versions['outputs']['suites'], '${{ steps.scope.outputs.suites }}')
        ids = [step.get('id') for step in versions['steps']]
        self.assertLess(ids.index('versions'), ids.index('scope'))
        scope = versions['steps'][ids.index('scope')]
        self.assertEqual(scope['run'], 'python3 scripts/ci-scope.py')
        self.assertEqual(scope['env']['RELEASE'], '${{ steps.versions.outputs.any }}')
        self.assertEqual(scope['env']['BEFORE'], '${{ github.event.before }}')
        self.assertEqual(versions['permissions'], {'contents': 'read', 'pull-requests': 'read', 'checks': 'read'})

    def test_ci_passed_reports_success_when_no_suite_runs(self):
        # Merged pull requests and release pull requests skip every suite and still pass the required check.
        job = self.jobs['ci-passed']
        self.assertEqual(job['if'], 'always()')
        self.assertEqual([step['if'] for step in job['steps']],
                         ["contains(needs.*.result, 'failure') || contains(needs.*.result, 'cancelled')"])
        self.assertEqual(job['needs'][:2], ['workflow-lint', 'versions'])
        self.assertTrue(set(job['needs'][2:]) <= {'checks'} | {n for n in self.jobs if n.startswith('test-')})

    def test_a_release_cannot_be_tagged_with_a_skipped_suite(self):
        # If the suites were ever wrong for a release, its skipped tests would block the tag, never pass it.
        base = WorkflowTests.base(self)
        for name in [name for name in self.jobs if name.startswith('test-')] + ['checks']:
            self.assertFalse(condition(self.jobs['tag']['if'], {**base, f'needs.{name}.result': 'skipped'}), name)

    def test_releases_manual_runs_and_unknown_pull_requests_test_every_suite(self):
        nowhere = Path('/nonexistent')
        for event in ['push', 'pull_request', 'workflow_dispatch']:
            for release in ['true', 'false']:
                suites, _ = self.scope.scope({'GITHUB_EVENT_NAME': event, 'RELEASE': release, 'BEFORE': 'f' * 40}, nowhere)
                self.assertEqual(suites, self.scope.EVERYTHING, (event, release))


def run(*args, cwd):
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


class ScopeHistoryTests(unittest.TestCase):
    """Pushes to main in a scratch repository, with GitHub's answers faked."""
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git('init', '-q', '-b', 'main')
        for key, value in [('user.name', 'Scope test'), ('user.email', 'test@example.invalid')]:
            self.git('config', key, value)
        (self.root / 'scripts').mkdir()
        (self.root / 'scripts/ci-scope.py').write_text((ROOT / 'scripts/ci-scope.py').read_text())
        # Loading the script writes its bytecode beside it, unless the interpreter keeps a cache elsewhere
        # as macOS's python3 does; CI's does not, and a commit picking it up is a change to scripts/.
        (self.root / '.gitignore').write_text('__pycache__/\n')
        self.base = self.commit('Base', 'README')
        self.scope = ci_scope(self.root)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.answers = {}
        self.scope.gh = self.answer

    def answer(self, path):
        for key, value in self.answers.items():
            if key in path:
                if isinstance(value, Exception):
                    raise value
                return value
        raise subprocess.CalledProcessError(1, ['gh', 'api', path])

    def git(self, *args):
        return run('git', *args, cwd=self.root)

    def commit(self, message, path):
        (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        (self.root / path).write_text(message)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', message)
        return self.git('rev-parse', 'HEAD')

    def pull_request(self, branch='feature'):
        self.git('checkout', '-q', '-b', branch, self.base)
        head = self.commit('Feature', f'Mobile/{branch}.swift')
        self.git('checkout', '-q', 'main')
        return head

    def merge(self, head, squash=False):
        if squash:
            self.git('merge', '-q', '--squash', head)
            return self.commit('Squashed', 'Mobile/squashed.swift')
        self.git('merge', '-q', '--no-ff', '-m', 'Merge pull request #7', head)
        return self.git('rev-parse', 'HEAD')

    def green(self, sha, head, conclusion='success', slug='github-actions', status='completed', base='main'):
        self.answers = {
            f'commits/{sha}/pulls': [{'number': 7, 'merged_at': '2026-10-21T10:00:00Z', 'merge_commit_sha': sha,
                                      'base': {'ref': base}, 'head': {'sha': head}}],
            f'commits/{head}/check-runs': {'check_runs': [
                {'status': 'completed', 'conclusion': 'failure', 'started_at': '2026-10-21T08:00:00Z',
                 'app': {'slug': 'github-actions'}},
                {'status': status, 'conclusion': conclusion, 'started_at': '2026-10-21T09:00:00Z', 'app': {'slug': slug}}]},
        }

    def push(self, sha, before, release='false'):
        return self.scope.scope({'GITHUB_EVENT_NAME': 'push', 'GITHUB_SHA': sha, 'BEFORE': before,
                                 'GITHUB_REPOSITORY': 'pdparchitect/noodle', 'RELEASE': release}, self.root)[0]

    def test_push_that_merges_a_green_pull_request_runs_nothing_unless_it_releases(self):
        for squash in [False, True]:
            with self.subTest(squash=squash):
                # Main may have moved on since the pull request's run: the next release runs everything.
                before = self.commit(f'Elsewhere {squash}', f'Browser/{squash}.swift')
                head = self.pull_request(branch=f'feature-{squash}')
                sha = self.merge(head, squash)
                self.green(sha, head)
                self.assertEqual(self.push(sha, before), [])
                self.assertEqual(self.push(sha, before, release='true'), self.scope.EVERYTHING)

    def test_merge_github_never_linked_to_its_pull_request_still_runs_nothing(self):
        # As #142's merge: GitHub listed no pull request for the commit, and its CI passed on a re-run.
        before = self.commit('Elsewhere', 'Browser/elsewhere.swift')
        head = self.pull_request()
        sha = self.merge(head)
        merged = {'number': 7, 'merged_at': '2026-10-22T17:56:35Z', 'merge_commit_sha': sha,
                  'base': {'ref': 'main'}, 'head': {'sha': head}}
        other = {'number': 6, 'merged_at': '2026-10-22T10:30:27Z', 'merge_commit_sha': before,
                 'base': {'ref': 'main'}, 'head': {'sha': before}}
        runs = {'check_runs': [
            {'id': 119947378273, 'status': 'completed', 'conclusion': 'success', 'started_at': '2026-10-22T16:25:39Z',
             'completed_at': '2026-10-22T16:25:43Z', 'app': {'slug': 'github-actions'}},
            {'id': 119927641548, 'status': 'completed', 'conclusion': 'failure', 'started_at': '2026-10-22T15:49:13Z',
             'completed_at': '2026-10-22T15:49:16Z', 'app': {'slug': 'github-actions'}}]}
        for closed, expected in [([{'number': 8, 'merged_at': None, 'merge_commit_sha': 'a' * 40,
                                    'base': {'ref': 'main'}, 'head': {'sha': 'b' * 40}}, merged, other], True),
                                 ([other], False), (subprocess.CalledProcessError(1, ['gh']), False)]:
            with self.subTest(closed=closed):
                self.answers = {f'commits/{sha}/pulls': [], 'pulls?state=closed&base=main': closed,
                                f'commits/{head}/check-runs': runs}
                self.assertEqual(self.push(sha, before) == [], expected)

    def test_every_other_push_runs_every_suite(self):
        head = self.pull_request()
        sha = self.merge(head)
        for answers in [
            lambda: self.green(sha, head, conclusion='failure'),
            lambda: self.green(sha, head, conclusion=None, status='in_progress'),
            lambda: self.green(sha, head, slug='someone-else'),
            lambda: self.green(sha, head, base='release'),
            lambda: self.green('0' * 40, head),
            lambda: self.answers.clear(),
            lambda: self.answers.update({'pulls': OSError('gh is missing')}),
        ]:
            answers()
            self.assertEqual(self.push(sha, self.base), self.scope.EVERYTHING)
        self.green(sha, head)
        self.assertEqual(self.push(sha, self.base), [])
        # Unknown or rewritten history, or more than the pull request's own commit, runs everything.
        for before in ['0' * 40, 'f' * 40, '']:
            self.assertEqual(self.push(sha, before), self.scope.EVERYTHING, before)
        # Not the pull request's own commit alone, so it runs what it changes since then: here nothing.
        self.assertEqual(self.push(sha, head), ['checks'])
        direct = self.commit('Direct', 'Sources/direct.swift')
        self.green(direct, head)
        self.assertEqual(self.push(direct, self.base), self.scope.EVERYTHING)
    def pull_request_run(self, *paths, release='true'):
        # GitHub tests a pull request as a merge of its branch into main.
        branch = f'pull-{len(self.git("branch").splitlines())}'
        self.git('checkout', '-q', '-b', branch, 'main')
        for path in paths:
            self.commit(f'Change {path}', path)
        self.git('checkout', '-q', '--detach', 'main')
        self.git('merge', '-q', '--no-ff', '-m', 'Test merge', branch)
        try:
            return self.scope.scope({'GITHUB_EVENT_NAME': 'pull_request', 'RELEASE': release}, self.root)[0]
        finally:
            self.git('checkout', '-q', 'main')

    def test_release_pull_request_runs_nothing_and_its_release_run_everything(self):
        release = ['VERSION', 'CHANGELOG.md', 'Mobile/VERSION', 'Mobile/CHANGELOG.md', 'Computer/Images/VERSION']
        self.assertEqual(self.pull_request_run(*release), [])
        self.assertEqual(self.pull_request_run('Hub/VERSION', 'Hub/CHANGELOG.md', release='false'), [])
        # This fixture has no manifests, so none of these can be placed and each runs every suite.
        for other in ['.github/workflows/release.yml', 'scripts/release-versions.py', 'Mobile/VERSION.txt',
                      'Mobile/Sources/VERSION.swift', 'CHANGELOG.md.orig']:
            self.assertEqual(self.pull_request_run(*release, other), self.scope.EVERYTHING, other)
        self.assertEqual(self.pull_request_run('Mobile/Chat.swift', release='false'), self.scope.EVERYTHING)
        # Merged, it is a release, whose run tests everything before publishing even though the pull request passed.
        head = self.pull_request(branch='release')
        sha = self.merge(head)
        self.green(sha, head)
        self.assertEqual(self.push(sha, self.base, release='true'), self.scope.EVERYTHING)

class PathScopeTests(unittest.TestCase):
    """Which suites a change runs: scripts/ci-scope.py against the real manifests and workflow."""
    @classmethod
    def setUpClass(cls):
        cls.scope = ci_scope()
        cls.nodes = cls.scope.graph()
        cls.flow = workflow('release.yml')
        cls.jobs = cls.flow['jobs']
        cls.everything = cls.scope.EVERYTHING

    def suites(self, *paths):
        return self.scope.affected(list(paths), self.nodes)

    def test_suites_cover_the_packages_and_scripts_their_jobs_use(self):
        self.assertEqual(self.everything, ['checks', *self.scope.SUITES])
        for suite, (roots, _) in self.scope.SUITES.items():
            runs = '\n'.join(step.get('run', '') for step in self.jobs['test-' + suite]['steps'])
            for command in re.findall(r'swift (?:test|build)\b[^\n]*', runs):
                package = re.search(r'--package-path (\S+)', command)
                self.assertIn(package[1] if package else '', roots, f'{suite}: {command}')
            for script in re.findall(r'(?<![\w/])(?:scripts|Tests)/[\w./-]+\.(?:sh|py)', runs):
                self.assertIn(suite, self.suites(script), f'{suite}: {script}')
        self.assertIn('Mobile', self.scope.SUITES['mobile'][0])

    def test_ignored_files_are_the_ones_the_trigger_leaves_out(self):
        triggers = self.flow.get('on', self.flow.get('true'))
        for event in ['push', 'pull_request']:
            self.assertEqual(triggers[event]['paths'], ['**'] + ['!' + pattern for pattern in self.scope.IGNORED])

    def test_changes_run_every_suite_that_depends_on_them(self):
        root = ['checks', 'noodle', 'noodle-macos27', 'hub']
        applet = ['applet', 'applet-rendering']
        cases = [
            (['Mobile/Sources/NoodleMobile/HubChats.swift'], ['checks', 'mobile']),
            (['Mobile/Project.swift', 'Mobile/Tests/NoodleMobileTests/HubChatsTests.swift'], ['checks', 'mobile']),
            (['Browser/Sources/NoodleBrowser/Tabs.swift'], ['checks', 'browser']),
            (['Hub/Sources/NoodleHub/HubApp.swift', 'Hub/Support/Info.plist'], ['checks', 'hub']),
            (['Applet/Sources/NoodleApplet/AppDelegate.swift'], ['checks', *applet]),
            # A Swift file named like a manifest is still Applet's source.
            (['Applet/Sources/AppletCore/Package.swift'], ['checks', *applet]),
            (['Computer/Sources/ComputerCore/Machine.swift'], ['checks', 'computer']),
            (['Computer/LocalMac/Sources/LocalMacCore/Account.swift'], ['checks', 'computer']),
            (['Computer/Images/desktop/Dockerfile'], ['checks', 'computer']),
            (['Push/Sources/PushCore/PushService.swift', 'Push/worker/src/index.ts'], ['checks', 'shared']),
            (['Sources/NoodleCore/Bot.swift'], root),
            (['Tests/NoodleAppTests/ScreenCaptureTests.swift'], root),
            (['Tools/Maps/Sources/NoodleMapsTools/Maps.swift'], root),
            (['Package.swift', 'Package.resolved', 'VERSION'], root),
            # Mobile bundles the voice previews from the root's Support folder.
            (['Support/VoicePreviews/ava.m4a'], root + ['mobile']),
            (['Shared/ExternalTools/Sources/NoodleExternalTools/Access.swift'], ['checks', 'shared', 'computer', 'browser']),
            (['Shared/HubLink/Sources/HubLink/Pairing.swift'], ['checks', 'noodle', 'shared', 'noodle-macos27', 'hub', 'mobile']),
            (['Shared/Patch/Sources/NoodlePatch/Patch.swift'], ['checks', 'noodle', 'shared', 'noodle-macos27', 'hub', 'mobile']),
            (['Computer/Bridge/Sources/ComputerBridge/Bridge.swift'],
             ['checks', 'noodle', 'noodle-macos27', 'computer', 'bridge', 'hub']),
            (['Applet/Protocol/Sources/AppletBridge/Request.swift'],
             ['checks', 'noodle', 'noodle-macos27', *applet, 'hub', 'mobile']),
            (['Browser/BrowserProtocol/Sources/BrowserBridge/Bridge.swift'],
             ['checks', 'noodle', 'noodle-macos27', 'browser', 'hub']),
            (['Shared/SettingsUI/Sources/NoodleSettingsUI/Window.swift'],
             [suite for suite in self.everything if suite not in ['bridge', 'mobile']]),
            # Every protocol is built on the live views.
            (['Shared/Surface/Sources/NoodleSurface/Surface.swift'], self.everything),
            (['scripts/mobile.sh'], ['checks', 'mobile']),
            (['scripts/build-mlx-metal.sh'], ['checks', 'noodle-macos27']),
            (['Mobile/Sources/NoodleMobile/Chat.swift', 'Browser/Sources/NoodleBrowser/Tabs.swift'],
             ['checks', 'browser', 'mobile']),
            # Documentation never widens a run; on its own it does not start one.
            (['Mobile/README.md', 'docs/releases.md', 'website/index.html', 'Scenarios/launch-week/script.json'], ['checks']),
            (['Mobile/CHANGELOG.md', 'Mobile/Sources/NoodleMobile/Chat.swift'], ['checks', 'mobile']),
        ]
        for paths, expected in cases:
            with self.subTest(paths=paths):
                self.assertEqual(self.suites(*paths), expected)

    def test_ci_release_automation_and_unknown_files_run_every_suite(self):
        for path in ['.github/workflows/release.yml', '.github/workflows/computer-images.yml',
                     'Tests/ReleaseAutomation/test_workflows.py', 'scripts/ci-scope.py', 'scripts/release-versions.py',
                     'scripts/package-xcode-release.sh', '.gitattributes', 'Makefile', 'Shared/unplaced.txt']:
            with self.subTest(path=path):
                self.assertEqual(self.suites(path), self.everything)
                self.assertEqual(self.suites('Mobile/Sources/NoodleMobile/Chat.swift', path), self.everything)


class PathScopeHistoryTests(ScopeHistoryTests):
    """The same scratch history, now with packages, so pull requests and other pushes run what they change."""
    def setUp(self):
        super().setUp()
        for manifest, kind in [('Package.swift', 'Package'), ('Browser/Package.swift', 'Package'),
                               ('Mobile/Project.swift', 'Project')]:
            (self.root / manifest).parent.mkdir(parents=True, exist_ok=True)
            (self.root / manifest).write_text(f'import {kind}Description\n')
        # The Hub builds on the root package.
        (self.root / 'Hub').mkdir()
        (self.root / 'Hub/Package.swift').write_text('import PackageDescription\n.package(path: "..")\n')
        self.base = self.commit('Manifests', 'Mobile/Sources/.keep')

    # The inherited tests that expect every suite need a history this cannot place.
    test_every_other_push_runs_every_suite = None
    test_release_pull_request_runs_nothing_and_its_release_run_everything = None

    def test_pull_request_runs_what_its_merge_changes(self):
        self.assertEqual(self.pull_request_run('Browser/Sources/Tabs.swift', release='false'), ['checks', 'browser'])
        self.assertEqual(self.pull_request_run('Mobile/Sources/Chat.swift', 'Browser/Sources/Tabs.swift', release='false'),
                         ['checks', 'browser', 'mobile'])
        self.assertEqual(self.pull_request_run('Sources/Core.swift', release='false'),
                         ['checks', 'noodle', 'noodle-macos27', 'hub'])
        self.assertEqual(self.pull_request_run('Browser/Sources/Tabs.swift', release='true'), self.scope.EVERYTHING)
        # Release pull requests run nothing; a version change alongside code runs that code's suites.
        self.assertEqual(self.pull_request_run('VERSION', 'Mobile/VERSION', 'Mobile/CHANGELOG.md'), [])
        self.assertEqual(self.pull_request_run('Mobile/VERSION', 'Mobile/Sources/Chat.swift', release='false'),
                         ['checks', 'mobile'])
        # Main moved since the branch: only the pull request's own changes count.
        head = self.pull_request(branch='behind')
        self.commit('Elsewhere', 'Browser/Sources/Other.swift')
        self.git('checkout', '-q', '--detach', 'main')
        self.git('merge', '-q', '--no-ff', '-m', 'Test merge', head)
        self.assertEqual(self.scope.scope({'GITHUB_EVENT_NAME': 'pull_request', 'RELEASE': 'false'}, self.root)[0],
                         ['checks', 'mobile'])
        self.git('checkout', '-q', head)
        self.assertEqual(self.scope.scope({'GITHUB_EVENT_NAME': 'pull_request', 'RELEASE': 'false'}, self.root)[0],
                         self.scope.EVERYTHING)
        self.git('checkout', '-q', 'main')

    def test_other_pushes_run_what_they_change(self):
        head = self.pull_request()
        sha = self.merge(head)
        self.green(sha, head, conclusion='failure')
        self.assertEqual(self.push(sha, self.base), ['checks', 'mobile'])
        self.assertEqual(self.push(sha, self.base, release='true'), self.scope.EVERYTHING)
        direct = self.commit('Direct', 'Browser/Sources/Tabs.swift')
        self.assertEqual(self.push(direct, sha), ['checks', 'browser'])
        # Without the previous commit (a new or rewritten branch) nothing is known to have passed.
        for unknown in ['0' * 40, 'f' * 40, '']:
            self.assertEqual(self.push(direct, unknown), self.scope.EVERYTHING)

    def test_moved_files_count_where_they_left(self):
        before = self.commit('shared code\n' * 20, 'Browser/Sources/Shared.swift')
        self.git('mv', 'Browser/Sources/Shared.swift', 'Mobile/Sources/Shared.swift')
        self.git('commit', '-q', '-m', 'Move')
        self.assertEqual(self.push(self.git('rev-parse', 'HEAD'), before), ['checks', 'browser', 'mobile'])

class TestSpeedTests(unittest.TestCase):
    """What keeps the slowest suites short without testing less."""
    @classmethod
    def setUpClass(cls):
        cls.jobs = workflow('release.yml')['jobs']

    def runs(self, job):
        return '\n'.join(step.get('run', '') for step in self.jobs[job]['steps'])

    def test_hub_core_tests_run_once_with_the_root_package(self):
        # test-hub used to rebuild the whole root package for HubCoreTests, which test-noodle runs anyway.
        self.assertIn('name: "HubCoreTests"', (ROOT / 'Package.swift').read_text())
        tests = next(step for step in self.jobs['test-noodle']['steps'] if step.get('id') == 'tests')
        self.assertEqual(tests['run'], 'swift test --disable-sandbox --enable-code-coverage')
        self.assertNotIn('swift test', self.runs('test-hub'))
        self.assertIn('swift build --disable-sandbox --package-path Hub --scratch-path .build/hub', self.runs('test-hub'))
        # Whatever can change HubCore's tests also runs test-noodle, and a Hub release requires it.
        scope = ci_scope()
        for path in ['Sources/HubCore/HubBots.swift', 'Tests/HubCoreTests/HubBotsTests.swift']:
            self.assertIn('noodle', scope.affected([path]), path)

    def test_build_caches_restore_everywhere_but_only_main_saves_them(self):
        for job, built in [('test-noodle', 'tests'), ('test-hub', 'build')]:
            steps = self.jobs[job]['steps']
            restore = next(i for i, step in enumerate(steps) if step.get('uses') == 'actions/cache/restore@v5')
            save = next(i for i, step in enumerate(steps) if step.get('uses') == 'actions/cache/save@v5')
            build = next(i for i, step in enumerate(steps) if step.get('id') == built)
            self.assertLess(restore, build)
            self.assertLess(build, save)
            self.assertNotIn('if', steps[restore])
            self.assertEqual(steps[restore]['id'], 'build-cache')
            key = steps[restore]['with']['key']
            # A new toolchain or dependency set never reuses another's build products as an exact hit.
            self.assertIn('${{ steps.toolchain.outputs.id }}', key)
            self.assertIn("hashFiles('Package.resolved', 'Package.swift'", key)
            self.assertTrue(key.startswith(steps[restore]['with']['restore-keys']))
            self.assertEqual(steps[save]['with']['path'], steps[restore]['with']['path'])
            self.assertEqual(steps[save]['with']['key'], '${{ steps.build-cache.outputs.cache-primary-key }}')
            for event, ref, hit, outcome, saves in [
                ('push', 'refs/heads/main', 'false', 'success', True),
                ('workflow_dispatch', 'refs/heads/main', '', 'success', True),
                ('push', 'refs/heads/main', 'true', 'success', False),
                ('push', 'refs/heads/main', 'false', 'failure', False),
                ('pull_request', 'refs/pull/7/merge', 'false', 'success', False),
                ('workflow_dispatch', 'refs/heads/feature', 'false', 'success', False),
            ]:
                values = {'github.event_name': event, 'github.ref': ref,
                          'steps.build-cache.outputs.cache-hit': hit, f'steps.{built}.outcome': outcome}
                self.assertEqual(condition(steps[save]['if'], values), saves, (job, event, ref, hit, outcome))
        # The fixture app is signed afresh each run; the linked test bundle and coverage are rebuilt anyway.
        cached = next(step for step in self.jobs['test-noodle']['steps'] if step.get('id') == 'build-cache')['with']['path']
        for excluded in ['!.build/Sandbox CLI Tests.app', '!.build/**/*.xctest', '!.build/coverage']:
            self.assertIn(excluded, cached.splitlines())


if __name__ == '__main__':
    unittest.main()
