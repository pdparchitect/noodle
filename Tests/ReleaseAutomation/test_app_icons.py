"""Exercise symbol composition and SVG edits through macOS icon packaging."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == 'darwin', 'requires AppKit and iconutil')
class AppIconTests(unittest.TestCase):
    def generate(self, source, iconset, success=True):
        result = subprocess.run(['/bin/zsh', str(ROOT / 'scripts/generate-icon.sh'),
                                 str(source), str(iconset)], capture_output=True, text=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Icon generation failed', result.stderr)

    def package(self, iconset):
        target = iconset.with_suffix('.icns')
        result = subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(target)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = target.read_bytes()
        self.assertEqual(data[:4], b'icns')
        self.assertEqual(struct.unpack('>I', data[4:8])[0], len(data))
        return data

    def check_png(self, path, size):
        data = path.read_bytes()
        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(struct.unpack('>IIBB', data[16:26]), (size, size, 8, 6))
        compressed = bytearray()
        offset = 8
        while offset < len(data):
            length = struct.unpack('>I', data[offset:offset + 4])[0]
            if data[offset + 4:offset + 8] == b'IDAT':
                compressed.extend(data[offset + 8:offset + 8 + length])
            offset += length + 12
        # Every PNG scanline filter leaves the first pixel of the first row
        # unchanged because it has no preceding pixel or row.
        self.assertEqual(zlib.decompress(compressed)[4], 0, 'opaque exterior corner')

    def test_all_four_symbols_compose_standalone_icons_and_complete_iconsets(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name, support in [('Noodle', 'Support'), ('Computer', 'Computer/Support'),
                                  ('Applet', 'Applet/Support'), ('Browser', 'Browser/Support')]:
                with self.subTest(app=name):
                    root = Path(temporary) / name
                    root.mkdir()
                    source = root / 'AppSymbol.svg'
                    shutil.copyfile(ROOT / support / 'AppSymbol.svg', source)
                    original = source.read_bytes()
                    iconset = root / 'App.iconset'
                    self.generate(source, iconset)
                    self.assertEqual(source.read_bytes(), original)
                    symbol = ET.parse(source).getroot()
                    icon = ET.parse(root / 'AppIcon.svg').getroot()
                    ns = {'svg': 'http://www.w3.org/2000/svg'}
                    self.assertIsNotNone(icon.find('svg:g[@id="' + symbol.attrib['data-icon-background'] + '"]', ns))
                    self.assertFalse(any(element.attrib.get('id', '').startswith('icon-background-')
                                         for element in symbol.iter()))
                    self.assertNotIn('data-icon-background', icon.attrib)
                    self.assertEqual(
                        ET.canonicalize(ET.tostring(symbol.find('svg:g[@id="symbol"]', ns), encoding='unicode'), strip_text=True),
                        ET.canonicalize(ET.tostring(icon.find('svg:g[@id="symbol"]', ns), encoding='unicode'), strip_text=True))
                    for element in icon.iter():
                        self.assertNotIn(element.tag.rsplit('}', 1)[-1], ['image', 'script', 'foreignObject'])
                        self.assertFalse(any(key.endswith('href') for key in element.attrib))
                    self.assertEqual(len(list(iconset.glob('*.png'))), 10)
                    for size in [16, 32, 128, 256, 512]:
                        for scale in [1, 2]:
                            suffix = '@2x' if scale == 2 else ''
                            self.check_png(iconset / f'icon_{size}x{size}{suffix}.png', size * scale)
                    self.check_png(root / 'AppIcon.png', 1024)
                    self.assertEqual((root / 'AppIcon.png').read_bytes(),
                                     (iconset / 'icon_512x512@2x.png').read_bytes())
                    self.package(iconset)

    def test_symbol_edit_refreshes_full_svg_pngs_and_packaged_icon(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'AppSymbol.svg'
            shutil.copyfile(ROOT / 'Support/AppSymbol.svg', source)
            iconset = root / 'App.iconset'
            self.generate(source, iconset)
            previous = {path: path.read_bytes() for path in iconset.glob('*.png')}
            for name in ['AppIcon.svg', 'AppIcon.png']:
                previous[root / name] = (root / name).read_bytes()
            packaged = self.package(iconset)
            timestamp = source.stat().st_mtime_ns
            source.write_text(source.read_text().replace('#fdf2d7', '#ff0000'))
            os.utime(source, ns=(timestamp, timestamp))
            self.generate(source, iconset)
            for path, data in previous.items():
                self.assertNotEqual(path.read_bytes(), data, f'stale generated icon: {path.name}')
            self.assertNotEqual(self.package(iconset), packaged)

    def test_invalid_symbol_fails_instead_of_reusing_stale_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / 'AppSymbol.svg'
            source.write_text('not an SVG')
            for name in ['AppIcon.svg', 'AppIcon.png']:
                (source.parent / name).write_bytes(b'stale output')
            iconset = Path(temporary) / 'App.iconset'
            self.generate(source, iconset, success=False)
            self.assertFalse(iconset.exists())
            for name in ['AppIcon.svg', 'AppIcon.png']:
                self.assertEqual((source.parent / name).read_bytes(), b'stale output')


if __name__ == '__main__':
    unittest.main()
