#!/usr/bin/env python3
"""Assemble Suite snapshots from immutable published apps; never compile an app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
REPO = 'pdparchitect/noodle'
CHANNEL = 'suite-latest'
IMAGE = 'Noodle-Suite-arm64.dmg'
MANIFEST = 'suite-manifest.json'
ASSETS = [IMAGE, IMAGE + '.sha256', MANIFEST]
PRODUCTS = {
    'noodle': ('v', 'Noodle', 'com.pdparchitect.noodle'),
    'computer': ('computer-v', 'Noodle Computer', 'com.pdparchitect.noodle.computer'),
    'applet': ('applet-v', 'Noodle Applet', 'com.pdparchitect.noodle.applet'),
    'browser': ('browser-v', 'Noodle Browser', 'com.pdparchitect.noodle.browser'),
    'hub': ('hub-v', 'Noodle Hub', 'com.pdparchitect.noodle.hub'),
}
# Companions that join the Suite after their first stable release.
OPTIONAL = {'browser', 'hub'}
SEMVER = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
RECIPE_FILES = ['scripts/suite-release.py', 'scripts/build-dmg.py', 'scripts/package-dmg.sh',
                'scripts/dmg-background.swift', 'scripts/dmg-requirements.txt']


def command(*args):
    return subprocess.check_output(args, text=True).strip()


class GitHub:
    def releases(self):
        result = []
        for page in range(1, 1001):
            batch = json.loads(command('gh', 'api', f'repos/{REPO}/releases?per_page=100&page={page}'))
            result.extend(batch)
            if len(batch) < 100:
                return result
        raise ValueError('Too many releases to resolve safely')

    def download(self, release, names, directory):
        directory.mkdir(parents=True, exist_ok=True)
        args = ['gh', 'release', 'download', release['tag_name'], '--repo', REPO, '--dir', str(directory)]
        for name in names:
            args.extend(['--pattern', name])
        command(*args)


def asset_names(release):
    return {asset['name'] for asset in release['assets']}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def snapshot_tag(manifest):
    return 'suite-' + hashlib.sha256(canonical(manifest)).hexdigest()[:24]


def recipe_digest():
    digest = hashlib.sha256()
    for name in RECIPE_FILES:
        digest.update(name.encode() + b'\0' + (ROOT / name).read_bytes() + b'\0')
    return digest.hexdigest()


def checksum_value(path, name):
    entries = path.read_text().splitlines()
    if len(entries) != 1:
        raise ValueError(f'Expected one checksum for {name}')
    match = re.fullmatch(r'([0-9a-f]{64}) [ *]' + re.escape(name), entries[0])
    if not match:
        raise ValueError(f'Invalid checksum for {name}')
    return match[1]


def verify_checksum(path, digest):
    hasher = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            hasher.update(block)
    if hasher.hexdigest() != digest:
        raise ValueError(f'Checksum mismatch: {path.name}')


def select_releases(releases):
    selected = {}
    for product, (prefix, name, _) in PRODUCTS.items():
        candidates = []
        for release in releases:
            match = re.fullmatch(re.escape(prefix) + SEMVER, release['tag_name'])
            if match and not release['draft'] and not release['prerelease']:
                candidates.append((tuple(map(int, match.groups())), release))
        if not candidates:
            if product in OPTIONAL:
                continue  # Joins automatically after its first stable release.
            raise ValueError(f'No stable {name} release is available')
        selected[product] = max(candidates, key=lambda item: item[0])[1]
    return selected


def resolve_manifest(github, releases, recipe):
    components = []
    with tempfile.TemporaryDirectory(prefix='suite-plan-') as temporary:
        for product, release in select_releases(releases).items():
            prefix, name, _ = PRODUCTS[product]
            version = release['tag_name'][len(prefix):]
            basename = name.replace(' ', '-')
            legacy = 'macOS' if product == 'noodle' else 'arm64'
            candidates = [f'{basename}-arm64.zip', f'{basename}-{version}-{legacy}.zip']
            names = asset_names(release)
            archive = next((item for item in candidates if {item, item + '.sha256'} <= names), None)
            if not archive:
                raise ValueError(f"Missing verified archive in {release['tag_name']}")
            directory = Path(temporary) / product
            github.download(release, [archive + '.sha256'], directory)
            digest = checksum_value(directory / (archive + '.sha256'), archive)
            components.append(dict(product=product, version=version, tag=release['tag_name'],
                                   archive=archive, sha256=digest))
    return dict(schema=1, recipe_sha256=recipe, minimum_macos='26.0', components=components)


def remote_manifest(github, release):
    with tempfile.TemporaryDirectory(prefix='suite-manifest-') as temporary:
        directory = Path(temporary)
        github.download(release, [MANIFEST], directory)
        return json.loads((directory / MANIFEST).read_text())


def plan(github, recipe):
    releases = github.releases()
    manifest = resolve_manifest(github, releases, recipe)
    tag = snapshot_tag(manifest)
    by_tag = {release['tag_name']: release for release in releases}
    channel = by_tag.get(CHANNEL)
    if (channel and not channel['draft'] and set(ASSETS) <= asset_names(channel)
            and remote_manifest(github, channel) == manifest):
        action = 'none'
    elif tag in by_tag:
        existing = by_tag[tag]
        if not set(ASSETS) <= asset_names(existing) or remote_manifest(github, existing) != manifest:
            raise ValueError(f'Incomplete Suite snapshot {tag}; restore its saved verified assets before retrying')
        action = 'reuse'
    else:
        action = 'build'
    return dict(manifest=manifest, tag=tag, action=action)


def verify_app(app, component):
    product = component['product']
    _, _, bundle_id = PRODUCTS[product]
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info['CFBundleIdentifier'] != bundle_id or info['CFBundleShortVersionString'] != component['version']:
        raise ValueError(f'Unexpected identity/version in {app.name}')
    expected_feed = (f'https://github.com/{REPO}/releases/latest/download/appcast.xml' if product == 'noodle'
                     else f'https://github.com/{REPO}/releases/download/{product}-latest/appcast.xml')
    if info.get('SUFeedURL') != expected_feed:
        raise ValueError(f'Unexpected updater channel in {app.name}')
    minimum = tuple(map(int, info.get('LSMinimumSystemVersion', '0').split('.')))
    if minimum > (26, 0, 0):
        raise ValueError(f'{app.name} requires a newer macOS version than Suite advertises')
    command('codesign', '--verify', '--deep', '--strict', str(app))
    signature = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(app)], stderr=subprocess.STDOUT, text=True)
    team = re.search(r'^TeamIdentifier=(\w+)$', signature, re.M)
    if 'Authority=Developer ID Application:' not in signature or not team:
        raise ValueError(f'{app.name} lacks a Developer ID signature')
    if command('lipo', '-archs', str(app / 'Contents/MacOS' / info['CFBundleExecutable'])) != 'arm64':
        raise ValueError(f'{app.name} is not the Apple silicon release')
    command('xcrun', 'stapler', 'validate', str(app))
    command('spctl', '--assess', '--type', 'execute', str(app))
    return team[1]


def release_notes(manifest):
    rows = [f"| {PRODUCTS[item['product']][1]} | [{item['version']}](https://github.com/{REPO}/releases/tag/{item['tag']}) |"
            for item in manifest['components']]
    tag = snapshot_tag(manifest)
    return (f'[Download Noodle Suite for Apple silicon](https://github.com/{REPO}/releases/download/{tag}/{IMAGE})\n\n'
            'Requires macOS 26 or later. Open the DMG and drag the apps to Applications.\n\n'
            '| App | Version |\n| --- | --- |\n' + '\n'.join(rows) + '\n\n'
            'Each app keeps its own automatic updates. This installer reuses the published app bundles.\n')


def verify_assets(directory, manifest):
    if json.loads((directory / MANIFEST).read_text()) != manifest:
        raise ValueError('Suite manifest differs from the planned app versions')
    verify_checksum(directory / IMAGE, checksum_value(directory / (IMAGE + '.sha256'), IMAGE))


def app_archive(github, component, downloads, cache=None):
    digest = component['sha256']
    cached = cache / (digest + '.zip') if cache else None
    if cached and cached.is_file():
        try:
            verify_checksum(cached, digest)
            return cached
        except ValueError:
            cached.unlink()  # A damaged cache is disposable; published assets remain authoritative.
    github.download({'tag_name': component['tag']}, [component['archive']], downloads)
    archive = downloads / component['archive']
    verify_checksum(archive, digest)
    if cached:
        cache.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(archive, cached)
    return archive


def fetch(github, planned, directory, cache=None):
    assets = directory / 'assets'
    assets.mkdir(parents=True)
    manifest = planned['manifest']
    if planned['action'] == 'reuse':
        github.download({'tag_name': planned['tag']}, ASSETS, assets)
        verify_assets(assets, manifest)
    elif planned['action'] == 'build':
        apps = directory / 'apps'
        apps.mkdir()
        teams = set()
        for component in manifest['components']:
            downloads = directory / 'downloads' / component['product']
            archive = app_archive(github, component, downloads, cache)
            name = PRODUCTS[component['product']][1] + '.app'
            with zipfile.ZipFile(archive) as zipped:
                for member in zipped.namelist():
                    path = Path(member)
                    if path.is_absolute() or '..' in path.parts or path.parts[0] not in [name, '__MACOSX']:
                        raise ValueError(f'Unexpected archive path: {member}')
            extracted = downloads / 'extracted'
            extracted.mkdir(parents=True)
            command('ditto', '-x', '-k', str(archive), str(extracted))
            app = extracted / name
            teams.add(verify_app(app, component))
            command('ditto', str(app), str(apps / name))
        if len(teams) != 1:
            raise ValueError('Suite apps must all be signed by the same publisher')
        if cache:
            keep = {item['sha256'] + '.zip' for item in manifest['components']}
            for path in cache.glob('*.zip'):
                if path.name not in keep:
                    path.unlink()
        (assets / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
    else:
        raise ValueError('Nothing to assemble')
    (assets / 'release-notes.md').write_text(release_notes(manifest))


def publish(github, planned, directory, source):
    manifest = planned['manifest']
    tag = snapshot_tag(manifest)
    verify_assets(directory, manifest)
    # Another app release can finish during notarization. Never replace the
    # channel with an older combination; the queued Suite run handles the new one.
    releases = github.releases()
    if resolve_manifest(github, releases, recipe_digest()) != manifest:
        print('Suite inputs changed during assembly; leaving the current channel intact.')
        return
    by_tag = {release['tag_name']: release for release in releases}
    existing = by_tag.get(tag)
    files = [str(directory / name) for name in ASSETS]
    title = 'Noodle Suite ' + tag.removeprefix('suite-')[:8]
    if existing:
        if planned['action'] != 'reuse' or remote_manifest(github, existing) != manifest:
            raise ValueError('Suite snapshot already exists; rerun to reuse its verified assets')
    else:
        command('gh', 'release', 'create', tag, *files, '--repo', REPO, '--target', source,
                '--draft', '--latest=false', '--title', title, '--notes-file', str(directory / 'release-notes.md'))
    command('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--latest=false')
    if CHANNEL in by_tag:
        # The immutable snapshot remains available throughout channel promotion.
        command('gh', 'release', 'upload', CHANNEL, *files[:2], '--repo', REPO, '--clobber')
        command('gh', 'release', 'edit', CHANNEL, '--repo', REPO, '--draft=false', '--latest=false',
                '--title', title, '--notes-file', str(directory / 'release-notes.md'))
        # The manifest is the completion marker. A partial upload must never
        # make the next planner mistake a damaged channel for a finished Suite.
        command('gh', 'release', 'upload', CHANNEL, files[2], '--repo', REPO, '--clobber')
    else:
        command('gh', 'release', 'create', CHANNEL, *files, '--repo', REPO, '--target', source,
                '--draft', '--latest=false', '--title', title, '--notes-file', str(directory / 'release-notes.md'))
        command('gh', 'release', 'edit', CHANNEL, '--repo', REPO, '--draft=false', '--latest=false')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['plan', 'fetch', 'publish'])
    parser.add_argument('--plan', type=Path, default=Path('dist/suite-plan.json'))
    parser.add_argument('--directory', type=Path, default=Path('dist/suite'))
    parser.add_argument('--cache', type=Path, help='Reuse checksum-verified published app ZIPs')
    args = parser.parse_args()
    github = GitHub()
    if args.command == 'plan':
        planned = plan(github, recipe_digest())
        planned['source'] = command('git', 'rev-parse', 'HEAD')
        args.plan.parent.mkdir(parents=True, exist_ok=True)
        args.plan.write_text(json.dumps(planned, indent=2) + '\n')
        print(f"Suite: {planned['action']} {planned['tag']}")
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(f"action={planned['action']}\nsource={planned['source']}\ntag={planned['tag']}\n")
    else:
        planned = json.loads(args.plan.read_text())
        if planned['tag'] != snapshot_tag(planned['manifest']):
            raise ValueError('Invalid Suite plan fingerprint')
        if args.command == 'fetch':
            fetch(github, planned, args.directory, args.cache)
        else:
            publish(github, planned, args.directory / 'assets', planned['source'])


if __name__ == '__main__':
    main()
