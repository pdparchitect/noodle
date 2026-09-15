#!/usr/bin/env python3
"""Extract lightweight keyboard lettering from the user-supplied MacBook model."""
import argparse
import collections
import json
import math
import struct
import zipfile
from pathlib import Path


def simplify_contour(loop, tolerance=0.003):
    """Reduce straight/curved edges within 0.08 pixels at the CSS model's size."""
    points = loop + [loop[0]]
    keep = {0, len(loop)}
    pending = [(0, len(loop))]
    while pending:
        start, end = pending.pop()
        if end - start < 2:
            continue
        a, b = points[start], points[end]
        dx, dy = b[0] - a[0], b[1] - a[1]
        length_squared = dx * dx + dy * dy
        farthest, max_distance = -1, 0
        for index in range(start + 1, end):
            point = points[index]
            t = max(0, min(1, ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / length_squared)) if length_squared else 0
            distance = math.hypot(point[0] - a[0] - t * dx, point[1] - a[1] - t * dy)
            if distance > max_distance:
                farthest, max_distance = index, distance
        if max_distance > tolerance:
            keep.add(farthest)
            pending.extend([(start, farthest), (farthest, end)])
    return [points[index] for index in sorted(keep)[:-1]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--output', type=Path, default=Path('website/assets/keyboard-legends.svg'))
    args = parser.parse_args()
    with zipfile.ZipFile(args.archive) as archive:
        source = archive.read('source/macbook_pro_14_inch_M5.glb')
    assert source[:4] == b'glTF'
    json_size = struct.unpack_from('<I', source, 12)[0]
    model = json.loads(source[20:20 + json_size])
    binary = source[28 + json_size:]

    def read_accessor(index):
        accessor = model['accessors'][index]
        view = model['bufferViews'][accessor['bufferView']]
        assert not view.get('byteStride'), 'Interleaved source requires a different extractor'
        component = {5126: 'f', 5123: 'H', 5125: 'I'}[accessor['componentType']]
        count = accessor['count'] * {'SCALAR': 1, 'VEC3': 3}[accessor['type']]
        offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
        return struct.unpack_from('<' + component * count, binary, offset)

    primitive = model['meshes'][27]['primitives'][0]
    assert model['meshes'][27]['name'] == 'wyClPAIazRlKQnt', 'Unexpected model layout'
    positions = read_accessor(primitive['attributes']['POSITION'])
    indices = read_accessor(primitive['indices'])
    # Flatten the raised lettering to the deck plane and weld duplicate vertices.
    points, ids, welded = [], [], {}
    for index in range(0, len(positions), 3):
        point = (round(positions[index], 6), round(positions[index + 1], 6))
        if point not in welded:
            welded[point] = len(points)
            points.append(point)
        ids.append(welded[point])
    edges = collections.Counter()
    for index in range(0, len(indices), 3):
        a, b, c = (ids[item] for item in indices[index:index + 3])
        if len({a, b, c}) < 3:
            continue
        for first, second in [(a, b), (b, c), (c, a)]:
            edges[tuple(sorted((first, second)))] += 1
    boundary = {edge for edge, count in edges.items() if count == 1}
    neighbors = collections.defaultdict(set)
    for first, second in boundary:
        neighbors[first].add(second)
        neighbors[second].add(first)
    assert all(len(adjacent) == 2 for adjacent in neighbors.values()), 'Expected closed letter contours'
    loops = []
    while boundary:
        start, current = min(boundary)
        boundary.remove((start, current))
        loop = [start, current]
        while current != start:
            following = next(other for other in sorted(neighbors[current]) if tuple(sorted((current, other))) in boundary)
            boundary.remove(tuple(sorted((current, following))))
            current = following
            loop.append(current)
        loops.append(simplify_contour([points[index] for index in loop[:-1]]))

    scale, paths = 800 / 31.173, []
    for loop in loops:
        coords = [(round((x + 13.935) * scale, 1), round((y + 9.39) * scale, 1)) for x, y in loop]
        paths.append('M' + ' '.join(f'{x:g},{y:g}' for x, y in coords) + 'Z')
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 716 295"><path fill="#a1a4aa" fill-rule="evenodd" d="' + ''.join(paths) + '"/></svg>\n'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(svg)
    print(f'{len(loops)} letter contours; {len(svg):,} SVG bytes')


if __name__ == '__main__':
    main()
