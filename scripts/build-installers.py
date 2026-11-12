#!/usr/bin/env python3
"""Build the Noodle and Noodle Hub Installer packages from a fetched Suite; never compile an app.

    python3 scripts/suite-release.py plan && python3 scripts/suite-release.py fetch
    python3 scripts/build-installers.py dist/suite                     # unsigned, for a local look
    python3 scripts/build-installers.py dist/suite --sign "Developer ID Installer: …" --notarize

Reads the verified apps in SUITE/apps, the `noodle` command in SUITE/command and the versions in
SUITE/assets/suite-manifest.json, and writes Noodle-Installer.pkg and Noodle-Hub-Installer.pkg with
their checksums to SUITE/assets. Each app becomes a component package for /Applications and the
command one for /usr/local/bin; each installer is a product archive whose choices page lists them.
Notarizing uses scripts/notarize.sh and its APPLE_API_KEY_* variables.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / 'scripts/installer'
_spec = importlib.util.spec_from_file_location('suite_release', ROOT / 'scripts/suite-release.py')
suite = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(suite)

# Receipts and MDM inventories track these; never rename one.
PACKAGES = {product: 'com.pdparchitect.noodle.pkg.' + product
            for product in ['noodle', 'computer', 'browser', 'applet', 'hub', 'terminal']}
# The one-line descriptions from the README's Apps table, shown under the choices.
DESCRIPTIONS = {
    'noodle': 'Personal AI agents that get things done.',
    'computer': 'Linux, macOS and Windows computers for you and your agents.',
    'browser': 'Dedicated browsers you sign in to and assign to agents, with persistent profiles, tabs, '
               'history, bookmarks, and file transfers.',
    'applet': 'Run tools, websites, experiments, and games created by you and your agents.',
    'hub': 'Share your harnesses with family and friends from an always-on Mac. Their bots run there, '
           'with your sign-ins kept on the Hub.',
    'terminal': 'Chat with the bots and groups on your Noodle Hub from a terminal. Installs the noodle '
                'command in /usr/local/bin.',
}
# Used when a bundle does not say; the command has no bundle to say it.
MINIMUM_MACOS = {'applet': '15.0'}
DEFAULT_MINIMUM = '26.0'
# Optional choices checked at the start; the command is for people who want it.
UNCHECKED = {'terminal'}
COMPANIONS = ['computer', 'browser', 'applet', 'terminal']
INSTALLERS = {
    'Noodle-Installer.pkg': dict(title='Noodle', identifier='com.pdparchitect.noodle.pkg.installer',
                                 required='noodle', optional=COMPANIONS, resources='Noodle'),
    'Noodle-Hub-Installer.pkg': dict(title='Noodle Hub', identifier='com.pdparchitect.noodle.pkg.hub-installer',
                                     required='hub', optional=COMPANIONS, resources='Hub'),
}
assert list(INSTALLERS) == suite.INSTALLERS


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def name(product):
    return suite.PRODUCTS[product][1]


def macos(version):
    # '26.0' reads as macOS 26, '26.2' as macOS 26.2.
    return 'macOS ' + version.removesuffix('.0')


def kilobytes(path):
    paths = [path] if path.is_file() else [item for item in path.rglob('*') if item.is_file() and not item.is_symlink()]
    return max(1, math.ceil(sum(item.lstat().st_size for item in paths) / 1024))


def components(directory):
    """The published apps and command of a fetched Suite, checked against its manifest."""
    manifest = json.loads((directory / 'assets' / suite.MANIFEST).read_text())
    found = {}
    for component in manifest['components']:
        product, version = component['product'], component['version']
        if product in suite.COMMANDS:
            root = directory / 'command' / 'noodle'
            if not root.is_file():
                raise ValueError(f'{name(product)} is missing from {directory}')
            minimum = MINIMUM_MACOS.get(product, DEFAULT_MINIMUM)
        else:
            root = directory / 'apps' / (name(product) + '.app')
            info = plistlib.loads((root / 'Contents/Info.plist').read_bytes())
            if (info.get('CFBundleIdentifier') != suite.PRODUCTS[product][2]
                    or info.get('CFBundleShortVersionString') != version):
                raise ValueError(f'{name(product)} differs from the Suite manifest')
            minimum = info.get('LSMinimumSystemVersion') or MINIMUM_MACOS.get(product, DEFAULT_MINIMUM)
        found[product] = dict(root=root, version=version, minimum=minimum, kbytes=kilobytes(root))
    return found


def distribution(installer, items):
    """The Distribution file: a choices page that is always shown, checks for Apple silicon and the
    required app's macOS, and a greyed-out row saying why for any companion this Mac cannot run."""
    spec = INSTALLERS[installer]
    required = spec['required']
    if required not in items:
        raise ValueError(f'{name(required)} has no published release to install')
    optional = [product for product in spec['optional'] if product in items]
    minimum = items[required]['minimum']

    def attributes(**values):
        return ''.join(f' {key}={quoteattr(value)}' for key, value in values.items())

    outline, choices, references = [], [], []
    for product in [required, *optional]:
        item = items[product]
        check = f"supports('{item['minimum']}')"
        outline.append(product)
        reference = f'        <pkg-ref id="{PACKAGES[product]}"/>\n'
        if product == required:
            choices.append(f'    <choice{attributes(id=product, title=name(product), description=DESCRIPTIONS[product], start_selected="true", selected="true", enabled="false")}>\n'
                           f'{reference}    </choice>\n')
        else:
            selected = 'false' if product in UNCHECKED else check
            choices.append(f'    <choice{attributes(id=product, title=name(product), description=DESCRIPTIONS[product], start_visible=check, start_enabled=check, start_selected=selected)}>\n'
                           f'{reference}    </choice>\n')
            # Installer cannot explain a disabled choice, so a stand-in row with the reason replaces it.
            reason = f"{DESCRIPTIONS[product]} Needs {macos(item['minimum'])} or later."
            outline.append(product + '.unavailable')
            choices.append(f'    <choice{attributes(id=product + ".unavailable", title=name(product), description=reason, start_visible="!" + check, start_selected="false", selected="false", enabled="false")}/>\n')
        references.append(f'    <pkg-ref{attributes(id=PACKAGES[product], version=item["version"], installKBytes=str(item["kbytes"]), onConclusion="none")}>#{product}.pkg</pkg-ref>\n')

    title = spec['title']
    lines = ''.join(f'        <line choice="{choice}"/>\n' for choice in outline)
    return f'''<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>{escape(title)}</title>
    <product{attributes(id=spec['identifier'], version=items[required]['version'])}/>
    <welcome file="welcome.html" mime-type="text/html"/>
    <readme file="readme.html" mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="always" require-scripts="false" hostArchitectures="arm64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <allowed-os-versions>
        <os-version min="{minimum}"/>
    </allowed-os-versions>
    <installation-check script="installationCheck()"/>
    <script><![CDATA[
function supports(version) {{
    return system.compareVersions(system.version.ProductVersion, version) >= 0;
}}
function installationCheck() {{
    if (system.sysctl('hw.optional.arm64') != 1) {{
        my.result.type = 'Fatal';
        my.result.title = {json.dumps(f'{title} needs a Mac with Apple silicon.')};
        my.result.message = 'This Mac has an Intel processor.';
        return false;
    }}
    if (!supports('{minimum}')) {{
        my.result.type = 'Fatal';
        my.result.title = {json.dumps(f'{title} needs {macos(minimum)} or later.')};
        my.result.message = 'Update macOS in System Settings, then open this installer again.';
        return false;
    }}
    return true;
}}
]]></script>
    <choices-outline>
{lines}    </choices-outline>
{''.join(choices)}{''.join(references)}</installer-gui-script>
'''


def component_package(product, item, packages, work):
    """One app for /Applications, or the command for /usr/local/bin, as a component package."""
    packages.mkdir(parents=True, exist_ok=True)
    root = work / ('root-' + product)
    arguments = ['pkgbuild', '--root', str(root), '--identifier', PACKAGES[product], '--version', item['version'],
                 '--install-location', '/', '--ownership', 'recommended']
    if product in suite.COMMANDS:
        target = root / 'usr/local/bin/noodle'
        target.parent.mkdir(parents=True)
        command('ditto', str(item['root']), str(target))
        target.chmod(0o755)
    else:
        bundle = 'Applications/' + item['root'].name
        command('ditto', str(item['root']), str(root / bundle))
        # Always /Applications, never another copy found elsewhere, and never over a newer version
        # that the app's own updater already installed.
        settings = work / (product + '-component.plist')
        settings.write_bytes(plistlib.dumps([dict(RootRelativeBundlePath=bundle, BundleIsRelocatable=False,
                                                  BundleIsVersionChecked=True, BundleHasStrictIdentifier=True,
                                                  BundleOverwriteAction='upgrade')]))
        arguments += ['--component-plist', str(settings)]
    # pkgbuild would carry the build Mac's download mark onto every Mac that installs. Only that goes;
    # anything else, such as a code signature kept beside a file, stays. (macOS keeps its own
    # com.apple.provenance mark where a sandbox adds it, and Installer does not apply that one.)
    subprocess.run(['xattr', '-r', '-d', 'com.apple.quarantine', str(root)], capture_output=True)  # Fails where a file has none.
    output = packages / (product + '.pkg')
    command(*arguments, str(output))
    return output


def check_signing(sign, notarize):
    if sign and not sign.startswith('Developer ID Installer:'):
        raise ValueError('Installer packages are signed with a Developer ID Installer identity')
    if notarize and not sign:
        raise ValueError('Only signed installers can be notarized')


def build(directory, sign=None, notarize=False):
    check_signing(sign, notarize)
    assets = directory / 'assets'
    for installer in INSTALLERS:
        for path in [assets / installer, assets / (installer + '.sha256')]:
            if path.exists():
                raise ValueError(f'{path} already exists')
    items = components(directory)
    built = []
    with tempfile.TemporaryDirectory(prefix='installers-', dir=directory) as temporary:
        work = Path(temporary)
        packages = work / 'packages'
        for product, item in items.items():
            component_package(product, item, packages, work)
        for installer, spec in INSTALLERS.items():
            plan = work / (installer + '.xml')
            plan.write_text(distribution(installer, items))
            staged = work / installer
            arguments = ['productbuild', '--distribution', str(plan), '--package-path', str(packages),
                         '--resources', str(RESOURCES / spec['resources'])]
            if sign:
                arguments += ['--sign', sign, '--timestamp']
            command(*arguments, str(staged))
            if sign:
                signature = subprocess.run(['pkgutil', '--check-signature', str(staged)],
                                           capture_output=True, text=True).stdout
                if 'Developer ID Installer:' not in signature:
                    raise ValueError(f'{installer} is not signed with a Developer ID Installer identity')
            if notarize:
                command('zsh', str(ROOT / 'scripts/notarize.sh'), str(staged))
                command('xcrun', 'stapler', 'staple', str(staged))
                command('xcrun', 'stapler', 'validate', str(staged))
                command('spctl', '--assess', '--type', 'install', str(staged))
            # Checksums cover the final stapled bytes; only fully verified output is moved into place.
            digest = hashlib.sha256(staged.read_bytes()).hexdigest()
            assets.mkdir(parents=True, exist_ok=True)
            (assets / (installer + '.sha256')).write_text(f'{digest}  {installer}\n')
            shutil.move(staged, assets / installer)
            built.append(assets / installer)
    return built


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('suite', type=Path, nargs='?', default=Path('dist/suite'),
                        help='A Suite folder from scripts/suite-release.py fetch')
    parser.add_argument('--sign', default=os.environ.get('NOODLE_INSTALLER_IDENTITY'),
                        help='Developer ID Installer identity; leave out for an unsigned local build')
    parser.add_argument('--notarize', action='store_true', help='Notarize and staple the signed installers')
    args = parser.parse_args()
    for path in build(args.suite, args.sign, args.notarize):
        print(path)


if __name__ == '__main__':
    main()
