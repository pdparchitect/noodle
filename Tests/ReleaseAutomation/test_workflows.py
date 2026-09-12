"""Exercise the real workflow dependency conditions, without GitHub or secrets."""
import itertools
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

    def test_product_selection_and_parallel_tests(self):
        for selected, expected in [
            (['noodle'], ['noodle', 'bridge']),
            (['computer'], ['noodle', 'computer', 'bridge']),
            (['applet'], ['noodle', 'applet', 'bridge']),
            (['images'], []),
            ([], []),
        ]:
            values = {**self.base(), **{f'needs.versions.outputs.{p}': str(p in selected).lower()
                                      for p in ['noodle', 'computer', 'applet', 'images']}}
            for product in ['noodle', 'computer', 'applet', 'bridge']:
                job = self.jobs['test-' + product]
                self.assertEqual(condition(job['if'], values), product in expected)
                self.assertEqual(job['needs'], ['versions', 'checks'])
        self.assertNotIn('test-computer', self.jobs['prepare-noodle']['needs'])
        self.assertEqual(self.jobs['prepare-images']['needs'], ['versions', 'checks'])
        self.assertNotIn('swift test', json.dumps(self.jobs['checks']))

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
        self.assertEqual(triggers['push'], {'branches': ['main']})
        for name in ['prepare-noodle-release.yml', 'computer-release.yml', 'applet-release.yml', 'computer-images.yml']:
            child = workflow(name)
            self.assertNotIn('push', child.get('on', child.get('true')))
        self.assertEqual(self.jobs['tag']['needs'], [
            'versions', 'workflow-lint', 'checks', 'test-noodle', 'test-computer', 'test-applet', 'test-bridge',
            'prepare-noodle', 'prepare-computer', 'prepare-applet', 'prepare-images'])


if __name__ == '__main__':
    unittest.main()
