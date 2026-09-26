"""Exercise the real workflow dependency conditions, without GitHub or secrets."""
import itertools
import fnmatch
import hashlib
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
            **{f'needs.test-{p}.result': 'success' for p in ['noodle', 'shared', 'computer', 'applet', 'browser', 'hub', 'mobile', 'bridge']},
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

    def test_all_suites_run_independently_of_version_changes(self):
        # Every workflow trigger runs the tests. Release selection still gates
        # preparation/publication, but must never suppress ordinary main CI.
        for product in ['noodle', 'shared', 'computer', 'applet', 'browser', 'hub', 'mobile', 'bridge']:
            job = self.jobs['test-' + product]
            self.assertNotIn('if', job)
            self.assertEqual(job['needs'], ['versions'])
            self.assertEqual(job['runs-on'], 'macos-26')
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
        self.assertNotIn('if', job)
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
            'versions', 'workflow-lint', 'checks', 'test-noodle', 'test-shared', 'test-noodle-macos27', 'test-computer', 'test-applet', 'test-browser', 'test-hub', 'test-mobile', 'test-bridge',
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


if __name__ == '__main__':
    unittest.main()
