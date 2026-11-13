"""The Noodle and Noodle Hub Installer packages, built from a fetched Suite without credentials or network."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ElementTree

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('installers', ROOT / 'scripts/build-installers.py')
installers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installers)
suite = installers.suite

MINIMUMS = {'noodle': '26.0', 'computer': '26.0', 'browser': '26.0', 'applet': '15.0', 'hub': '26.0'}
OPTIONAL = ['computer', 'browser', 'applet', 'terminal']


def components(**changes):
    result = {product: dict(version='1.2.3', kbytes=2048, minimum=MINIMUMS.get(product, '26.0'))
              for product in ['noodle', 'computer', 'browser', 'applet', 'hub', 'terminal']}
    for product, values in changes.items():
        result[product].update(values)
    return result


def parse(name, items=None):
    return ElementTree.fromstring(installers.distribution(name, items or components()))


def choices(root):
    return {choice.get('id'): choice for choice in root.iter('choice')}


def make_suite(directory, products=('noodle', 'computer', 'browser', 'applet', 'hub', 'terminal')):
    # Tiny stand-ins for the verified published apps that suite-release.py fetch leaves behind.
    entries = []
    for product in products:
        prefix, name, bundle_id = suite.PRODUCTS[product]
        entries.append(dict(product=product, version='1.2.3', tag=prefix + '1.2.3',
                            archive=name.replace(' ', '-') + '-arm64.zip', sha256='0' * 64))
        if product in suite.COMMANDS:
            path = directory / 'command' / 'noodle'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#!/bin/sh\necho noodle\n')
            path.chmod(0o755)
            continue
        app = directory / 'apps' / (name + '.app')
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': bundle_id, 'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '1',
            'CFBundleExecutable': name, 'CFBundlePackageType': 'APPL', 'CFBundleName': name,
            'LSMinimumSystemVersion': MINIMUMS[product]}))
        (app / 'Contents/MacOS' / name).write_text('#!/bin/sh\n')
    (directory / 'assets').mkdir(parents=True, exist_ok=True)
    manifest = dict(schema=1, recipe_sha256='a' * 64, minimum_macos='26.0', components=entries)
    (directory / 'assets' / suite.MANIFEST).write_text(json.dumps(manifest))
    return manifest


class DistributionTests(unittest.TestCase):
    def test_both_installers_always_show_the_choices_page_on_apple_silicon(self):
        for name in suite.INSTALLERS:
            with self.subTest(name=name):
                root = parse(name)
                options = root.find('options')
                self.assertEqual(options.get('customize'), 'always')
                self.assertEqual(options.get('hostArchitectures'), 'arm64')
                self.assertEqual(options.get('require-scripts'), 'false')
                self.assertEqual(root.find('domains').get('enable_localSystem'), 'true')
                self.assertEqual(root.find('domains').get('enable_currentUserHome'), 'false')
                for page in ['welcome', 'readme', 'conclusion']:
                    self.assertEqual(root.find(page).get('file'), page + '.html')

    def test_each_installer_requires_its_own_app_and_offers_the_companions(self):
        for name, required in [('Noodle-Suite-Installer.pkg', 'noodle'), ('Noodle-Hub-Installer.pkg', 'hub')]:
            with self.subTest(name=name):
                root = parse(name)
                found = choices(root)
                main = found[required]
                self.assertEqual(main.get('enabled'), 'false')  # Checked and greyed: it cannot be left out.
                self.assertEqual(main.get('selected'), 'true')
                self.assertEqual(main.get('start_selected'), 'true')
                outline = [line.get('choice') for line in root.find('choices-outline')]
                self.assertEqual([item for item in outline if not item.endswith('.unavailable')],
                                 [required, *OPTIONAL])
                other = 'hub' if required == 'noodle' else 'noodle'
                self.assertNotIn(other, found)
                for product in OPTIONAL:
                    self.assertNotEqual(found[product].get('enabled'), 'false')
                    self.assertEqual([ref.get('id') for ref in found[product].iter('pkg-ref')],
                                     [installers.PACKAGES[product]])
                self.assertEqual(root.find('product').get('id'), installers.INSTALLERS[name]['identifier'])
                self.assertEqual(root.find('product').get('version'), '1.2.3')

    def test_standalone_noodle_installs_only_noodle(self):
        root = parse('Noodle-Installer.pkg')
        self.assertEqual(set(choices(root)), {'noodle'})
        self.assertEqual(root.find('title').text, 'Noodle')
        self.assertEqual([ref.get('id') for ref in root.findall('pkg-ref')], [installers.PACKAGES['noodle']])

    def test_terminal_starts_unchecked_and_the_apps_checked(self):
        found = choices(parse('Noodle-Suite-Installer.pkg'))
        self.assertEqual(found['terminal'].get('start_selected'), 'false')
        for product in ['computer', 'browser', 'applet']:
            self.assertEqual(found[product].get('start_selected'), f"supports('{MINIMUMS[product]}')")

    def test_installer_checks_apple_silicon_and_the_required_apps_macos(self):
        for name, required in [('Noodle-Suite-Installer.pkg', 'noodle'), ('Noodle-Hub-Installer.pkg', 'hub')]:
            with self.subTest(name=name):
                root = parse(name, components(**{required: dict(minimum='26.1')}))
                self.assertEqual(root.find('allowed-os-versions/os-version').get('min'), '26.1')
                self.assertEqual(root.find('installation-check').get('script'), 'installationCheck()')
                script = root.find('script').text
                self.assertIn("system.sysctl('hw.optional.arm64')", script)
                self.assertIn("supports('26.1')", script)
                self.assertIn('Apple silicon', script)
                self.assertIn('macOS 26.1 or later', script)

    def test_choices_that_cannot_run_on_this_mac_are_greyed_out_with_the_reason(self):
        root = parse('Noodle-Suite-Installer.pkg', components(computer=dict(minimum='26.2')))
        found = choices(root)
        for product, minimum, label in [('computer', '26.2', 'macOS 26.2'), ('applet', '15.0', 'macOS 15'),
                                        ('browser', '26.0', 'macOS 26'), ('terminal', '26.0', 'macOS 26')]:
            with self.subTest(product=product):
                available = found[product]
                check = f"supports('{minimum}')"
                self.assertEqual(available.get('start_visible'), check)
                self.assertEqual(available.get('start_enabled'), check)
                unavailable = found[product + '.unavailable']
                self.assertEqual(unavailable.get('start_visible'), '!' + check)
                self.assertEqual(unavailable.get('enabled'), 'false')
                self.assertEqual(unavailable.get('selected'), 'false')
                self.assertEqual(unavailable.get('title'), available.get('title'))
                self.assertIn(f'Needs {label} or later.', unavailable.get('description'))
                self.assertEqual(list(unavailable.iter('pkg-ref')), [])

    def test_every_choice_has_a_title_description_version_and_size(self):
        for name in suite.INSTALLERS:
            root = parse(name, components(applet=dict(kbytes=4321)))
            refs = {ref.get('id'): ref for ref in root.findall('pkg-ref')}
            for choice in root.iter('choice'):
                with self.subTest(name=name, choice=choice.get('id')):
                    self.assertTrue(choice.get('title', '').startswith('Noodle'))
                    description = choice.get('description', '')
                    self.assertTrue(description.endswith('.'), description)
                    self.assertNotIn('...', description)
            if name == 'Noodle-Installer.pkg':
                self.assertEqual(set(refs), {installers.PACKAGES['noodle']})
                continue
            self.assertEqual(refs[installers.PACKAGES['applet']].get('installKBytes'), '4321')
            self.assertEqual(refs[installers.PACKAGES['applet']].get('version'), '1.2.3')
            self.assertEqual(refs[installers.PACKAGES['applet']].text, '#applet.pkg')

    def test_package_identifiers_never_change(self):
        # MDMs track what they installed by these identifiers; renaming one orphans every Mac's receipt.
        self.assertEqual(installers.PACKAGES, {
            'noodle': 'com.pdparchitect.noodle.pkg.noodle',
            'computer': 'com.pdparchitect.noodle.pkg.computer',
            'browser': 'com.pdparchitect.noodle.pkg.browser',
            'applet': 'com.pdparchitect.noodle.pkg.applet',
            'hub': 'com.pdparchitect.noodle.pkg.hub',
            'terminal': 'com.pdparchitect.noodle.pkg.terminal',
        })
        self.assertEqual({name: item['identifier'] for name, item in installers.INSTALLERS.items()}, {
            'Noodle-Suite-Installer.pkg': 'com.pdparchitect.noodle.pkg.suite-installer',
            'Noodle-Installer.pkg': 'com.pdparchitect.noodle.pkg.installer',
            'Noodle-Hub-Installer.pkg': 'com.pdparchitect.noodle.pkg.hub-installer',
        })

    def test_unpublished_companions_are_left_out_but_the_required_app_is_not(self):
        items = components()
        del items['terminal']
        found = choices(parse('Noodle-Suite-Installer.pkg', items))
        self.assertNotIn('terminal', found)
        self.assertNotIn('terminal.unavailable', found)
        del items['hub']
        with self.assertRaisesRegex(ValueError, 'Noodle Hub'):
            installers.distribution('Noodle-Hub-Installer.pkg', items)

    def test_pages_explain_each_app_in_light_and_dark(self):
        for name, item in installers.INSTALLERS.items():
            for page in ['welcome', 'readme', 'conclusion']:
                with self.subTest(name=name, page=page):
                    text = (installers.RESOURCES / item['resources'] / (page + '.html')).read_text()
                    self.assertIn('color-scheme', text)
                    self.assertNotIn('...', text)
            readme = (installers.RESOURCES / item['resources'] / 'readme.html').read_text()
            for product in [item['required'], *item['optional']]:
                self.assertIn(suite.PRODUCTS[product][1], readme)
            if item['optional']:
                self.assertIn('/usr/local/bin', readme)
            conclusion = (installers.RESOURCES / item['resources'] / 'conclusion.html').read_text()
            self.assertIn('first', conclusion)  # Permissions are asked for on first launch.
            self.assertIn('up to date', conclusion)
        for page in ['welcome', 'conclusion']:
            text = (installers.RESOURCES / 'Hub' / (page + '.html')).read_text()
            self.assertIn('always-on', text)
            self.assertIn('https://github.com/pdparchitect/noodle/blob/main/Hub/README.md', text)

    def test_resources_are_part_of_the_suite_recipe(self):
        for item in installers.INSTALLERS.values():
            for page in ['welcome', 'readme', 'conclusion']:
                path = (installers.RESOURCES / item['resources'] / (page + '.html')).relative_to(ROOT)
                self.assertIn(str(path), suite.RECIPE_FILES)
        self.assertIn('scripts/build-installers.py', suite.RECIPE_FILES)


class SuiteInputTests(unittest.TestCase):
    def test_components_come_from_the_verified_suite_with_their_minimum_macos(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            make_suite(directory)
            found = installers.components(directory)
            self.assertEqual(set(found), {'noodle', 'computer', 'browser', 'applet', 'hub', 'terminal'})
            self.assertEqual(found['applet']['minimum'], '15.0')
            self.assertEqual(found['terminal']['minimum'], '26.0')
            self.assertEqual(found['noodle']['root'], directory / 'apps/Noodle.app')
            self.assertEqual(found['terminal']['root'], directory / 'command/noodle')
            self.assertTrue(all(item['version'] == '1.2.3' for item in found.values()))

    def test_a_bundle_that_differs_from_the_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            make_suite(directory)
            info = directory / 'apps/Noodle Browser.app/Contents/Info.plist'
            for field, value in [('CFBundleShortVersionString', '1.2.4'), ('CFBundleIdentifier', 'example.fake')]:
                values = plistlib.loads(info.read_bytes())
                original = values[field]
                info.write_bytes(plistlib.dumps({**values, field: value}))
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'Noodle Browser'):
                    installers.components(directory)
                info.write_bytes(plistlib.dumps({**values, field: original}))

    def test_signing_needs_a_developer_id_installer_identity_and_notarizing_needs_signing(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(installers, 'command') as command:
            directory = Path(temporary)
            make_suite(directory)
            with self.assertRaisesRegex(ValueError, 'Developer ID Installer'):
                installers.build(directory, sign='Developer ID Application: Example (TEAM)')
            with self.assertRaisesRegex(ValueError, 'signed'):
                installers.build(directory, notarize=True)
            command.assert_not_called()


@unittest.skipUnless(shutil.which('pkgbuild') and shutil.which('productbuild'), 'Needs macOS packaging tools')
class LocalBuildTests(unittest.TestCase):
    def test_unsigned_local_build_makes_both_installers_with_checksums(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            make_suite(directory)
            built = installers.build(directory)
            assets = directory / 'assets'
            self.assertEqual(built, [assets / name for name in suite.INSTALLERS])
            for name in suite.INSTALLERS:
                with self.subTest(name=name):
                    package = assets / name
                    digest = hashlib.sha256(package.read_bytes()).hexdigest()
                    self.assertEqual((assets / (name + '.sha256')).read_text(), f'{digest}  {name}\n')
                    signature = subprocess.run(['pkgutil', '--check-signature', str(package)],
                                               capture_output=True, text=True)
                    self.assertIn('no signature', signature.stdout.lower())
                    expanded = directory / ('expanded-' + name)
                    subprocess.run(['pkgutil', '--expand', str(package), str(expanded)], check=True)
                    root = ElementTree.parse(expanded / 'Distribution').getroot()
                    self.assertEqual(root.find('options').get('customize'), 'always')
                    for page in ['welcome', 'readme', 'conclusion']:
                        self.assertTrue((expanded / 'Resources' / (page + '.html')).is_file())
                    required = installers.INSTALLERS[name]['required']
                    self.assertTrue((expanded / (required + '.pkg')).is_dir())
            # Nothing is overwritten: a second build into the same folder is refused.
            with self.assertRaisesRegex(ValueError, 'already exists'):
                installers.build(directory)

    def test_apps_install_into_applications_and_terminal_into_usr_local_bin(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            make_suite(directory, products=('noodle', 'terminal'))
            for path in [directory / 'apps/Noodle.app/Contents/Info.plist', directory / 'command/noodle']:
                subprocess.run(['xattr', '-w', 'com.apple.quarantine', '0081;00000000;Test;', str(path)], check=True)
            found = installers.components(directory)
            packages = directory / 'packages'
            for product, expected in [('noodle', 'Applications/Noodle.app/Contents/Info.plist'),
                                      ('terminal', 'usr/local/bin/noodle')]:
                with self.subTest(product=product):
                    package = installers.component_package(product, found[product], packages, directory / 'work')
                    files = subprocess.check_output(['pkgutil', '--payload-files', str(package)], text=True)
                    self.assertIn('./' + expected, files.splitlines())
                    expanded = directory / ('expanded-' + product)
                    subprocess.run(['pkgutil', '--expand-full', str(package), str(expanded)], check=True)
                    # The build Mac's download mark is not installed with the apps.
                    marks = subprocess.run(['xattr', str(expanded / 'Payload' / expected)], capture_output=True, text=True)
                    self.assertEqual(marks.returncode, 0)
                    self.assertNotIn('com.apple.quarantine', marks.stdout)
                    info = ElementTree.parse(expanded / 'PackageInfo').getroot()
                    self.assertEqual(info.get('identifier'), installers.PACKAGES[product])
                    self.assertEqual(info.get('version'), '1.2.3')
                    self.assertEqual(info.get('install-location'), '/')
                    if product == 'noodle':
                        bundle = info.find('bundle')
                        self.assertEqual(bundle.get('id'), suite.PRODUCTS['noodle'][2])
                        # Installs into /Applications even when another copy lives elsewhere.
                        self.assertIsNone(info.find('relocate/bundle'))


if __name__ == '__main__':
    unittest.main()
