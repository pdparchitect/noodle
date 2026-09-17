#!/usr/bin/env python3
"""Build and inspect a Finder installer without requiring a GUI session."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


def settings(app, background):
    return {
        'format': 'UDZO',
        'filesystem': 'HFS+',
        'files': [str(app)],
        'symlinks': {'Applications': '/Applications'},
        'background': str(background),
        'window_rect': ((200, 200), (660, 400)),
        'icon_locations': {app.name: (165, 200), 'Applications': (495, 200)},
        'icon_size': 160,
        'text_size': 16,
        'show_icon_preview': True,
        # SetFile's hide-extension flag adds FinderInfo to the app and breaks
        # strict code-signature verification. Leave the signed bundle untouched.
        'default_view': 'icon-view',
        'show_status_bar': False,
        'show_tab_view': False,
        'show_toolbar': False,
        'show_pathbar': False,
        'show_sidebar': False,
        'arrange_by': None,
        'create_hook': prepare_volume,
    }


def prepare_volume(mount, options):
    # dmgbuild uses ditto to preserve the app. Fail before publication if the
    # copy is incomplete or its code signature is no longer valid.
    app = Path(options['files'][0])
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(Path(mount) / app.name)], check=True)


def verify_image(image, app):
    from ds_store import DSStore
    from mac_alias import Alias

    subprocess.run(['hdiutil', 'verify', str(image)], check=True)
    with tempfile.TemporaryDirectory(prefix='noodle-dmg-check-') as temporary:
        mount = Path(temporary) / 'volume'
        attached = plistlib.loads(subprocess.check_output([
            'hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
            '-mountpoint', str(mount), '-plist', str(image),
        ]))
        device = next(entry['dev-entry'] for entry in attached['system-entities'] if 'mount-point' in entry)
        try:
            copied_app = mount / app.name
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(copied_app)], check=True)
            if (copied_app / 'Contents/Info.plist').read_bytes() != (app / 'Contents/Info.plist').read_bytes():
                raise ValueError('DMG app metadata differs from the source app')
            if not (mount / 'Applications').is_symlink() or (mount / 'Applications').readlink() != Path('/Applications'):
                raise ValueError('DMG must link to /Applications')
            with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
                window = store['.']['bwsp']
                icons = store['.']['icvp']
                if (window['WindowBounds'] != '{{200, 200}, {660, 400}}'
                        or any(window[key] for key in ['ShowToolbar', 'ShowSidebar', 'ShowStatusBar', 'ShowTabView', 'ShowPathbar'])
                        or icons['iconSize'] != 160 or icons['textSize'] != 16
                        or icons['backgroundType'] != 2 or icons['arrangeBy'] != 'none'
                        or store[app.name]['Iloc'] != (165, 200)
                        or store['Applications']['Iloc'] != (495, 200)):
                    raise ValueError('DMG Finder layout does not match the installer design')
                alias = Alias.from_bytes(icons['backgroundImageAlias'])
                if alias.target.filename != '.background.tiff' or not (mount / '.background.tiff').is_file():
                    raise ValueError('DMG background is missing')
        finally:
            subprocess.run(['hdiutil', 'detach', device], check=True)


def main():
    import dmgbuild

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('background', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    # Preserve the bundle name even when the source is a development symlink.
    app = args.app.absolute()
    if app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file():
        parser.error('Expected an application bundle')
    if args.output.exists():
        parser.error('Refusing to overwrite an existing disk image')
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    dmgbuild.build_dmg(str(args.output), app.stem + ' Installer', settings=settings(app, args.background))
    verify_image(args.output, app)


if __name__ == '__main__':
    main()
