#!/usr/bin/env python3
"""Publish the development Computer at a path its managed accounts can read."""
import ctypes
from contextlib import ExitStack
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LOCAL_ID = 'com.pdparchitect.noodle.computer.local'


def require_local(app):
    with (app / 'Contents/Info.plist').open('rb') as stream:
        if plistlib.load(stream).get('CFBundleIdentifier') != LOCAL_ID:
            raise ValueError('Refusing to replace or install a non-development Computer bundle.')


def verify_signature(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)


def stop_running():
    subprocess.run(['/usr/bin/swift', str(Path(__file__).with_name('stop-computer-dev.swift'))], check=True)


def publish(staging, destination, replacing):
    if not replacing:
        os.rename(staging, destination)
        return
    # Both names are on the same volume. Exchange retains the old copy for rollback.
    library = ctypes.CDLL(None, use_errno=True)
    if library.renamex_np(os.fsencode(staging), os.fsencode(destination), 2) != 0:  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def install_local(source, destination, verify=verify_signature, exchange=publish, legacy_paths=(), stop=None):
    if destination.is_symlink() or destination.parent.resolve() != destination.parent:
        raise ValueError('The Dev Computer installation path must not be a symbolic link.')
    require_local(source)
    verify(source)
    if source.is_symlink():
        if source.resolve() != destination:
            raise ValueError('The Dev build points to an unexpected installation.')
        return destination
    if destination.exists():
        require_local(destination)
    # Preserve paths that actually need migration. Once an obsolete alias has
    # been retired, later builds must not recreate it and register the old name.
    legacy_paths = tuple(path for path in legacy_paths if path.exists() or path.is_symlink())
    for legacy in legacy_paths:
        if legacy.parent.resolve() != legacy.parent or legacy in (source, destination):
            raise ValueError('Unexpected legacy development installation path.')
        if legacy.exists():
            require_local(legacy)
        elif legacy.is_symlink():
            raise ValueError('Refusing an unresolved legacy installation alias.')
    with tempfile.TemporaryDirectory(prefix='.noodle-computer-install-', dir=destination.parent) as staging_root, \
         ExitStack() as aliases:
        staging = Path(staging_root) / destination.name
        subprocess.run(['/usr/bin/ditto', str(source), str(staging)], check=True)
        require_local(staging)
        verify(staging)
        # Complete staging first, then wait for a graceful quit before removing
        # the loaded image. Opening an already-running app does not restart it.
        (stop or stop_running)()
        replacing = destination.exists()
        exchange(staging, destination, replacing)
        published_aliases = []
        try:
            verify(destination)
            # Existing launchd registrations may still use the old .build path.
            # Preserve it as an alias; the service resolves its real executable
            # location before finding the account's desktop helper.
            # Keep only aliases at old build/install paths. Exact bundle IDs above
            # prevent this rename from replacing the production app or its data.
            for path in (source, *legacy_paths):
                alias_root = aliases.enter_context(tempfile.TemporaryDirectory(prefix='.computer-alias-', dir=path.parent))
                alias = Path(alias_root) / path.name
                alias.symlink_to(destination, target_is_directory=True)
                existed = path.exists() or path.is_symlink()
                exchange(alias, path, existed)
                published_aliases.append((alias, path, existed))
        except BaseException:
            for alias, path, existed in reversed(published_aliases):
                if existed:
                    exchange(alias, path, True)
                else:
                    path.unlink()
            if replacing:
                exchange(staging, destination, True)
            else:
                os.rename(destination, staging)
            raise
    return destination


def main():
    root = Path(__file__).resolve().parents[1]
    source = root / '.build/Noodle Computer Dev.app'
    if len(sys.argv) != 2 or Path(os.path.abspath(sys.argv[1])) != source:
        raise ValueError('Pass the built .build/Noodle Computer Dev.app bundle.')
    print(install_local(source, Path('/Applications/Noodle Computer Dev.app'), legacy_paths=(
        Path('/Applications/Noodle Computer Local.app'), root / '.build/Noodle Computer Local.app')))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'Dev Computer installation failed: {error}', file=sys.stderr)
        sys.exit(1)
