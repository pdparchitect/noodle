#!/usr/bin/env python3
"""Build and inspect a Finder installer without requiring a GUI session."""
import argparse
from pathlib import Path
import plistlib
import subprocess
import tempfile


SUITE_NAMES = ['Noodle.app', 'Noodle Computer.app', 'Noodle Applet.app', 'Noodle Browser.app']


def layout(apps, suite=False):
    if not suite:
        return (660, 400), {apps[0].name: (165, 200), 'Applications': (495, 200)}
    positions = [(165, 160), (405, 160), (165, 380), (405, 380)]
    if len(apps) == 3:
        positions[2] = (285, 380)
    return (900, 560), {**dict(zip((app.name for app in apps), positions)), 'Applications': (745, 270)}


def settings(apps, background, suite=False):
    size, locations = layout(apps, suite)
    return {
        'format': 'UDZO',
        'filesystem': 'HFS+',
        'files': [str(app) for app in apps],
        'symlinks': {'Applications': '/Applications'},
        'background': str(background),
        'window_rect': ((200, 200), size),
        'icon_locations': locations,
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
    for source in options['files']:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(Path(mount) / Path(source).name)], check=True)


def verify_image(image, apps, suite=False):
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
            for app in apps:
                copied_app = mount / app.name
                subprocess.run(['codesign', '--verify', '--deep', '--strict', str(copied_app)], check=True)
                if (copied_app / 'Contents/Info.plist').read_bytes() != (app / 'Contents/Info.plist').read_bytes():
                    raise ValueError('DMG app metadata differs from the source app')
            if not (mount / 'Applications').is_symlink() or (mount / 'Applications').readlink() != Path('/Applications'):
                raise ValueError('DMG must link to /Applications')
            with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
                window = store['.']['bwsp']
                icons = store['.']['icvp']
                (width, height), locations = layout(apps, suite)
                if (window['WindowBounds'] != f'{{{{200, 200}}, {{{width}, {height}}}}}'
                        or any(window[key] for key in ['ShowToolbar', 'ShowSidebar', 'ShowStatusBar', 'ShowTabView', 'ShowPathbar'])
                        or icons['iconSize'] != 160 or icons['textSize'] != 16
                        or icons['backgroundType'] != 2 or icons['arrangeBy'] != 'none'
                        or any(store[name]['Iloc'] != position for name, position in locations.items())):
                    raise ValueError('DMG Finder layout does not match the installer design')
                alias = Alias.from_bytes(icons['backgroundImageAlias'])
                if alias.target.filename != '.background.tiff' or not (mount / '.background.tiff').is_file():
                    raise ValueError('DMG background is missing')
        finally:
            subprocess.run(['hdiutil', 'detach', device], check=True)


def main():
    import dmgbuild

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', action='store_true', help='Package a directory of released Suite apps')
    parser.add_argument('app', type=Path)
    parser.add_argument('background', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    # Preserve the bundle name even when the source is a development symlink.
    source = args.app.absolute()
    if args.suite:
        names = {path.name for path in source.glob('*.app')}
        if names not in [set(SUITE_NAMES[:3]), set(SUITE_NAMES)]:
            parser.error('Suite requires Noodle, Computer, and Applet; Browser is optional until its first release')
        apps = [source / name for name in SUITE_NAMES if name in names]
    else:
        apps = [source]
    if any(app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file() for app in apps):
        parser.error('Expected application bundles')
    if args.output.exists():
        parser.error('Refusing to overwrite an existing disk image')
    for app in apps:
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    title = 'Noodle Suite Installer' if args.suite else apps[0].stem + ' Installer'
    dmgbuild.build_dmg(str(args.output), title, settings=settings(apps, args.background, args.suite))
    verify_image(args.output, apps, args.suite)


if __name__ == '__main__':
    main()
