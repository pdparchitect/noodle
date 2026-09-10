#!/usr/bin/env python3
"""Recover publication from a checked, tagged run; never build or move tags."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REPO = 'pdparchitect/noodle'
ROOT = Path(__file__).resolve().parent.parent


def command(*args, capture=False):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip() if capture else subprocess.check_call(args, cwd=ROOT)


def api(path):
    return json.loads(command('gh', 'api', f'repos/{REPO}/{path}', capture=True))


def validate(run, jobs, artifacts):
    if (run['status'] != 'completed' or run['head_branch'] != 'main'
            or run['path'] != '.github/workflows/release.yml'
            or not re.fullmatch('[0-9a-f]{40}', run['head_sha'])):
        raise ValueError('Expected a completed main release workflow')
    results = {job['name']: job['conclusion'] for job in jobs}
    for required in ['workflow-lint', 'versions', 'checks', 'tag']:
        if results.get(required) != 'success':
            raise ValueError(f'Required original gate did not pass: {required}')
    products = []
    for product, artifact, job in [
        ('images', 'computer-image-builds', 'prepare-images / build'),
        ('computer', 'computer-release-assets', 'prepare-computer / release'),
        ('noodle', 'noodle-release-assets', 'prepare-noodle / release'),
    ]:
        matches = [a for a in artifacts if a['name'] == artifact and not a['expired']]
        if results.get(job) == 'success':
            if len(matches) != 1:
                raise ValueError(f'Missing or ambiguous verified artifact: {artifact}')
            products.append((product, artifact))
    if not products:
        raise ValueError('No verified products to publish')
    return products


def checksum(directory, filename):
    entries = (directory / filename).read_text().splitlines()
    if not entries:
        raise ValueError('Empty checksum file')
    for entry in entries:
        digest, name = entry.split(maxsplit=1)
        name = name.lstrip('*')
        if Path(name).name != name or not re.fullmatch('[0-9a-f]{64}', digest):
            raise ValueError('Invalid checksum entry')
        with (directory / name).open('rb') as file:
            hasher = hashlib.sha256()
            for chunk in iter(lambda: file.read(1024 * 1024), b''):
                hasher.update(chunk)
            actual = hasher.hexdigest()
        if actual != digest:
            raise ValueError(f'Archive checksum mismatch: {name}')


def main():
    run_id = sys.argv[1]
    if not run_id.isdigit():
        raise ValueError('Expected a workflow run ID')
    run = api('actions/runs/' + run_id)
    jobs = api(f'actions/runs/{run_id}/jobs?per_page=100')['jobs']
    artifacts = api(f'actions/runs/{run_id}/artifacts?per_page=100')['artifacts']
    products = validate(run, jobs, artifacts)
    sha = run['head_sha']
    command('git', 'fetch', 'origin', sha, '--tags')
    command('git', 'checkout', '--detach', sha)
    spec = importlib.util.spec_from_file_location('versions', ROOT / 'scripts/release-versions.py')
    versions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(versions)
    for product, _ in products:
        _, tag = versions.version(product)
        if command('git', 'rev-parse', f'{tag}^{{commit}}', capture=True) != sha:
            raise ValueError(f'{tag} does not identify the prepared source')
    # All publishing helpers see the original checked source revision.
    os.environ['GITHUB_SHA'] = sha
    with tempfile.TemporaryDirectory() as temporary:
        downloads = {}
        for product, artifact in products:
            destination = Path(temporary) / product
            command('gh', 'run', 'download', run_id, '--repo', REPO,
                    '--name', artifact, '--dir', str(destination))
            downloads[product] = destination
        if 'images' in downloads:
            directory = downloads['images']
            checksum(directory, 'computer-images.tar.gz.sha256')
            command('docker', 'load', '--input', str(directory / 'computer-images.tar.gz'))
            command('bash', 'scripts/publish-computer-images.sh')
        if 'computer' in downloads:
            version, _ = versions.version('computer')
            directory = downloads['computer']
            checksum(directory, f'Noodle-Computer-{version}-arm64.zip.sha256')
            command('python3', 'scripts/computer-image-registry.py', 'channel')
            destination = ROOT / 'dist' / f'computer-{version}'
            destination.parent.mkdir(exist_ok=True)
            shutil.copytree(directory, destination)
            command('zsh', 'scripts/publish-computer-release.sh', version, str(destination / 'release-notes.md'))
        if 'noodle' in downloads:
            version, tag = versions.version('noodle')
            directory = downloads['noodle']
            archive = f'Noodle-{version}-macOS.zip'
            checksum(directory, archive + '.sha256')
            command('gh', 'release', 'create', tag, str(directory / archive),
                    str(directory / (archive + '.sha256')), str(directory / 'appcast.xml'),
                    '--repo', REPO, '--draft', '--verify-tag', '--title', f'Noodle {version}',
                    '--notes-file', str(directory / 'release-notes.md'))
            command('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--latest')


if __name__ == '__main__':
    main()
