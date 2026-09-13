"""Exercise the real workflow dependency conditions, without GitHub or secrets."""
import itertools
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
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
            **{f'needs.test-{p}.result': 'success' for p in ['noodle', 'computer', 'applet', 'bridge']},
            **{f'needs.versions.outputs.{p}': 'true' for p in ['noodle', 'computer', 'applet', 'images']},
            **{f'needs.prepare-{p}.result': 'success' for p in ['noodle', 'computer', 'applet', 'images']},
        }

    def test_tag_gate_blocks_failed_cancelled_or_skipped_selected_products(self):
        gate = self.jobs['tag']['if']
        for selected in itertools.product([False, True], repeat=4):
            if not any(selected):
                continue
            values = self.base()
            for product, active in zip(['noodle', 'computer', 'applet', 'images'], selected):
                values[f'needs.versions.outputs.{product}'] = str(active).lower()
                values[f'needs.prepare-{product}.result'] = 'success' if active else 'skipped'
            self.assertTrue(condition(gate, values))
            for product, active in zip(['noodle', 'computer', 'applet', 'images'], selected):
                if active:
                    for failure in ['failure', 'cancelled', 'skipped']:
                        self.assertFalse(condition(gate, {**values, f'needs.prepare-{product}.result': failure}))
        for result in ['failure', 'cancelled', 'skipped']:
            self.assertFalse(condition(gate, {**self.base(), 'needs.checks.result': result}))
            self.assertFalse(condition(gate, {**self.base(), 'needs.workflow-lint.result': result}))

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
        self.assertTrue(condition(noodle['if'], values))
        self.assertFalse(condition(noodle['if'], {**values, 'needs.publish-computer.result': 'failure'}))
        self.assertFalse(condition(noodle['if'], {**values, 'needs.publish-applet.result': 'failure'}))
        applet = self.jobs['publish-applet']
        self.assertTrue(condition(applet['if'], values))
        self.assertFalse(condition(applet['if'], {**values, 'needs.tag.result': 'failure'}))

    def test_all_suites_run_independently_of_version_changes(self):
        # Every workflow trigger runs the tests. Release selection still gates
        # preparation/publication, but must never suppress ordinary main CI.
        for product in ['noodle', 'computer', 'applet', 'bridge']:
            job = self.jobs['test-' + product]
            self.assertNotIn('if', job)
            self.assertEqual(job['needs'], ['versions', 'checks'])
            self.assertEqual(job['runs-on'], 'macos-26')
        self.assertNotIn('test-computer', self.jobs['prepare-noodle']['needs'])
        self.assertEqual(self.jobs['prepare-images']['needs'], ['versions', 'checks'])
        self.assertNotIn('swift test', json.dumps(self.jobs['checks']))

    def test_sandbox_helpers_and_adapter_recovery_are_required_before_coverage(self):
        steps = self.jobs['test-noodle']['steps']
        fixture = next(i for i, step in enumerate(steps)
                       if 'Tests/build-sandbox-cli-fixture.sh' in step.get('run', ''))
        delivery = next(i for i, step in enumerate(steps)
                        if 'Tests/message-delivery.sh' in step.get('run', ''))
        suite = next(i for i, step in enumerate(steps) if step.get('id') == 'tests')
        self.assertLess(fixture, suite)
        # The standalone swiftc fixture links uninstrumented SwiftPM objects.
        self.assertLess(delivery, suite)
        for index in [fixture, delivery, suite]:
            self.assertFalse(steps[index].get('continue-on-error', False))
            self.assertNotIn('if', steps[index])
        self.assertEqual(steps[suite]['env']['NOODLE_TEST_CLI_APPLICATION'],
                         '${{ github.workspace }}/.build/Sandbox CLI Tests.app')

    def test_selected_test_failures_block_tagging(self):
        for product in ['noodle', 'computer', 'applet', 'bridge']:
            for result in ['failure', 'cancelled', 'skipped']:
                self.assertFalse(condition(self.jobs['tag']['if'], {
                    **self.base(), f'needs.test-{product}.result': result}))
        # A Noodle-only release accepts skipped Computer tests and preparation.
        self.assertTrue(condition(self.jobs['tag']['if'], {
            **self.base(), 'needs.versions.outputs.computer': 'false',
            'needs.test-computer.result': 'skipped', 'needs.prepare-computer.result': 'skipped'}))

    def test_noodle_coverage_is_collected_without_masking_test_failures(self):
        steps = self.jobs['test-noodle']['steps']
        tests = next(step for step in steps if step.get('id') == 'tests')
        self.assertIn('--enable-code-coverage', tests['run'])
        self.assertFalse(tests.get('continue-on-error', False))
        report = next(step for step in steps if 'scripts/coverage-report.py' in step.get('run', ''))
        for outcome in ['success', 'failure']:
            self.assertTrue(condition(report['if'].removeprefix('${{').removesuffix('}}'), {'steps.tests.outcome': outcome}))
        self.assertIn('GITHUB_STEP_SUMMARY', report['run'])
        upload = next(step for step in steps if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertIn('!cancelled()', upload['if'])
        self.assertEqual(upload['with']['path'], '.build/coverage/noodle/')
        self.assertTrue(upload['with']['include-hidden-files'])
        self.assertEqual(upload['with']['name'], 'noodle-coverage')

    def test_incomplete_publication_cannot_report_release_success(self):
        complete = self.jobs['complete']
        self.assertIn('always()', complete['if'])
        step = complete['steps'][0]
        source = step['run'].split("\n", 1)[1].rsplit("\nPY", 1)[0]
        for selected in [['noodle'], ['computer', 'images'], ['applet'], ['noodle', 'applet'], ['images']]:
            environment = {**os.environ, 'RELEASE_PRODUCTS': json.dumps(selected),
                           **{p.upper() + '_RESULT': 'success' if p in selected else 'skipped'
                              for p in ['noodle', 'computer', 'applet', 'images']}}
            passed = subprocess.run(['python3', '-c', source], env=environment, capture_output=True)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            for product in selected:
                for failure in ['skipped', 'failure', 'cancelled']:
                    failed = subprocess.run(['python3', '-c', source], env={
                        **environment, product.upper() + '_RESULT': failure}, capture_output=True)
                    self.assertNotEqual(failed.returncode, 0)

    def test_preparation_is_read_only_and_publication_uses_artifacts(self):
        for name in ['prepare-noodle-release.yml', 'computer-release.yml', 'applet-release.yml', 'computer-images.yml']:
            prepare = workflow(name)
            self.assertEqual(prepare['permissions'], {'contents': 'read'})
            rendered = json.dumps(prepare)
            for write in ['gh release create', 'docker push', 'git push']:
                self.assertNotIn(write, rendered)
            self.assertIn('actions/upload-artifact@v6', rendered)
        for job in ['publish-noodle', 'publish-computer', 'publish-applet', 'publish-images']:
            self.assertIn('tag', self.jobs[job]['needs'])
            self.assertIn('actions/download-artifact@v7', json.dumps(self.jobs[job]))

    def test_computer_packaging_has_guest_helper_toolchain(self):
        steps = workflow('computer-release.yml')['jobs']['release']['steps']
        setup = next(i for i, step in enumerate(steps)
                     if step.get('uses', '').startswith('actions/setup-go@'))
        package = next(i for i, step in enumerate(steps)
                       if 'scripts/package-computer-release.sh' in step.get('run', ''))
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
        for name in ['prepare-noodle-release.yml', 'computer-release.yml', 'applet-release.yml', 'computer-images.yml']:
            child = workflow(name)
            self.assertNotIn('push', child.get('on', child.get('true')))
        self.assertEqual(self.jobs['tag']['needs'], [
            'versions', 'workflow-lint', 'checks', 'test-noodle', 'test-computer', 'test-applet', 'test-bridge',
            'prepare-noodle', 'prepare-computer', 'prepare-applet', 'prepare-images'])

    def test_documentation_only_changes_skip_app_ci_but_release_inputs_do_not(self):
        triggers = self.flow.get('on', self.flow.get('true'))
        docs = ['README.md', 'AGENTS.md', '.github/pull_request_template.md',
                'Computer/README.md', 'Computer/Bridge/README.md',
                'Computer/Images/README.md', 'Applet/RELEASING.md',
                'docs/releases.md', 'docs/noodle-architecture.svg',
                'docs/noodle-architecture.excalidraw.json', 'website/index.html',
                'website/assets/noodle.png']
        required = ['VERSION', 'Computer/VERSION', 'Applet/VERSION', 'Computer/Images/VERSION',
                    'CHANGELOG.md', 'Computer/CHANGELOG.md', 'Applet/CHANGELOG.md',
                    'Computer/Images/CHANGELOG.md', 'docs/message-reference.md',
                    'Sources/NoodleCore/MessengerDocumentation.swift', 'Package.swift',
                    'Tests/NoodleAppTests/ScreenCaptureTests.swift', 'scripts/build-app.sh',
                    'Support/AppIcon.png', 'Support/update-milestones.json',
                    'Computer/Images/desktop/Dockerfile', 'Applet/Support/Info.plist',
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

    def test_website_content_still_deploys_without_readme_only_runs(self):
        flow = workflow('website.yml')
        triggers = flow.get('on', flow.get('true'))
        patterns = triggers['push']['paths']
        self.assertEqual(triggers['push']['branches'], ['main'])
        self.assertIn('workflow_dispatch', triggers)
        self.assertFalse(matches_paths(['README.md', 'website/README.md', 'docs/website.md'], patterns))
        for path in ['website/index.html', 'website/assets/noodle.png',
                     'website/CNAME', '.github/workflows/website.yml']:
            with self.subTest(path=path):
                self.assertTrue(matches_paths(['website/README.md', path], patterns))


if __name__ == '__main__':
    unittest.main()
