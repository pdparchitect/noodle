#!/usr/bin/env python3
"""Prepare the user-supplied MacBook GLB for the optional website comparison."""
import argparse
import copy
import gzip
import json
import struct
import zipfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
parser.add_argument('--output', type=Path, default=Path('website/assets/macbook-m5.glb.gz'))
args = parser.parse_args()
with zipfile.ZipFile(args.archive) as archive:
    source = archive.read('source/macbook_pro_14_inch_M5.glb')
assert source[:4] == b'glTF'
json_size, _ = struct.unpack_from('<II', source, 12)
model = json.loads(source[20:20 + json_size])
binary = source[28 + json_size:]
old_views, old_accessors = model['bufferViews'], model['accessors']
views, accessors, output = [], [], bytearray()
accessor_map = {}

def add_buffer(data, target=None):
    output.extend(b'\0' * (-len(output) % 4))
    view = {'buffer': 0, 'byteOffset': len(output), 'byteLength': len(data)}
    if target:
        view['target'] = target
    views.append(view)
    output.extend(data)
    return len(views) - 1

def raw_accessor(index):
    accessor = old_accessors[index]
    view = old_views[accessor['bufferView']]
    assert not view.get('byteStride'), 'Interleaved source requires a different repacker'
    offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
    components = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[accessor['type']]
    size = {5121: 1, 5123: 2, 5125: 4, 5126: 4}[accessor['componentType']]
    return binary[offset:offset + accessor['count'] * components * size]

def keep_accessor(index):
    if index in accessor_map:
        return accessor_map[index]
    accessor = copy.deepcopy(old_accessors[index])
    view = old_views[accessor['bufferView']]
    accessor['bufferView'] = add_buffer(raw_accessor(index), view.get('target'))
    accessor.pop('byteOffset', None)
    accessor_map[index] = len(accessors)
    accessors.append(accessor)
    return accessor_map[index]

for mesh in model['meshes']:
    for primitive in mesh['primitives']:
        for name, index in list(primitive['attributes'].items()):
            if name.startswith('COLOR_'):
                # The source colors are entirely white, so they have no visual effect.
                assert all(value == 255 for value in raw_accessor(index))
                del primitive['attributes'][name]
            elif name == 'TEXCOORD_1':
                # No material references a second UV channel.
                assert 'texCoord' not in json.dumps(model['materials'])
                del primitive['attributes'][name]
            else:
                primitive['attributes'][name] = keep_accessor(index)
        primitive['indices'] = keep_accessor(primitive['indices'])

# The website supplies the Noodle screen, so remove the original wallpaper.
model['materials'][27].pop('emissiveTexture')
model['materials'][27]['emissiveFactor'] = [0, 0, 0]
used_textures = set()
def texture_refs(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key.endswith('Texture') and isinstance(child, dict):
                yield child
            else:
                yield from texture_refs(child)
    elif isinstance(value, list):
        for child in value:
            yield from texture_refs(child)
refs = list(texture_refs(model['materials']))
used_textures.update(ref['index'] for ref in refs)
texture_map = {old: new for new, old in enumerate(sorted(used_textures))}
textures = [model['textures'][index] for index in sorted(used_textures)]
for ref in refs:
    ref['index'] = texture_map[ref['index']]
image_map, images = {}, []
for texture in textures:
    old_index = texture['source']
    if old_index not in image_map:
        image = copy.deepcopy(model['images'][old_index])
        view = old_views[image['bufferView']]
        offset = view.get('byteOffset', 0)
        image['bufferView'] = add_buffer(binary[offset:offset + view['byteLength']])
        image_map[old_index] = len(images)
        images.append(image)
    texture['source'] = image_map[old_index]
model.update(bufferViews=views, accessors=accessors, textures=textures, images=images)
model['nodes'][43]['name'] = 'MacBookBase'
model['nodes'][61]['name'] = 'MacBookLid'
model['nodes'][70]['name'] = 'MacBook'
model['nodes'][57]['name'] = 'MacBookDisplay'
model['buffers'] = [{'byteLength': len(output)}]
model['asset']['extras'] = {'source': 'User-provided macbook-pro-14-inch-m5.zip', 'preparation': 'Remove unused white colors, secondary UVs, and wallpaper; preserve all geometry and materials.'}
header = json.dumps(model, separators=(',', ':')).encode()
header += b' ' * (-len(header) % 4)
output.extend(b'\0' * (-len(output) % 4))
glb = struct.pack('<III', 0x46546c67, 2, 28 + len(header) + len(output)) + struct.pack('<II', len(header), 0x4e4f534a) + header + struct.pack('<II', len(output), 0x004e4942) + output
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_bytes(gzip.compress(glb, compresslevel=9, mtime=0))
print(f'{len(source):,} source bytes → {len(glb):,} GLB bytes → {args.output.stat().st_size:,} compressed bytes')
