#!/usr/bin/env python3
"""Find an installed macOS 27 test toolchain without changing xcode-select."""
import json
import os
from pathlib import Path
import subprocess


def command(arguments, developer=None):
    environment = dict(os.environ)
    if developer:
        environment['DEVELOPER_DIR'] = developer
    try:
        return subprocess.check_output(arguments, env=environment, text=True,
                                       stderr=subprocess.DEVNULL, timeout=30).strip()
    except (OSError, subprocess.SubprocessError):
        return ''


def major(version):
    try:
        return int(version.split('.')[0])
    except ValueError:
        return 0


def full_xcodes():
    selected = os.environ.get('DEVELOPER_DIR') or command(['xcode-select', '-p'])
    candidates = ([Path(selected)] if selected else []) + sorted(
        Path('/Applications').glob('Xcode*.app/Contents/Developer'), reverse=True)
    found = []
    for candidate in candidates:
        if candidate.suffix == '.app':
            candidate /= 'Contents/Developer'
        candidate = candidate.resolve()
        if (candidate / 'Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework').is_dir():
            if str(candidate) not in found:
                found.append(str(candidate))
    return found


def toolchain(developer):
    version = command(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], developer)
    if major(version) < 27:
        return None
    sdk = command(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], developer)
    swift = command(['xcrun', '--find', 'swift'], developer)
    if not sdk or not swift or not Path(sdk).is_dir() or not os.access(swift, os.X_OK):
        return None
    return {'developer_dir': developer, 'sdk': str(Path(sdk).resolve()), 'swift': swift, 'sdk_version': version}


def detect():
    version = command(['sw_vers', '-productVersion'])
    if major(version) < 27:
        return {'available': False, 'reason': f'macOS 27 or later is required; found {version or "unknown OS"}.'}
    if command(['uname', '-m']) != 'arm64':
        return {'available': False, 'reason': 'The Apple/MLX harness tests require an Apple Silicon runner.'}
    developers = full_xcodes()
    if not developers:
        return {'available': False, 'reason': 'A full Xcode installation with XCTest is required.'}
    for developer in developers:
        if found := toolchain(developer):
            return {'available': True, 'reason': f'macOS {version}, SDK {found["sdk_version"]}.', **found}
    # Match the supported local setup: new CLT compiler/SDK plus full Xcode's
    # XCTest and platform macros. Only the isolated harness is built this way.
    if found := toolchain('/Library/Developer/CommandLineTools'):
        found['developer_dir'] = developers[0]
        return {'available': True, 'reason': f'macOS {version}, CLT SDK {found["sdk_version"]}, Xcode XCTest.', **found}
    return {'available': False, 'reason': 'No installed macOS 27 SDK and Swift compiler were found.'}


def report(result):
    print(json.dumps(result, indent=2))
    if output := os.environ.get('GITHUB_OUTPUT'):
        with open(output, 'a') as stream:
            for key, value in result.items():
                value = str(value).lower() if isinstance(value, bool) else str(value)
                if '\n' in value or '\r' in value:
                    raise ValueError('Toolchain output must contain one line per value.')
                stream.write(f'{key}={value}\n')
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as stream:
            state = 'Available' if result['available'] else 'Skipped'
            stream.write(f'### macOS 27 harness tests: {state}\n\n{result["reason"]}\n\n')


if __name__ == '__main__':
    report(detect())
