#!/usr/bin/env python3
"""Generate GTK symbolic PNG resources from the Openbox XBM controls."""

from __future__ import annotations

import argparse
import re
import struct
import zlib
from pathlib import Path


CONTROL_SOURCES = {
    "window-minimize-symbolic.symbolic.png": "iconify.xbm",
    "window-maximize-symbolic.symbolic.png": "max.xbm",
    "window-restore-symbolic.symbolic.png": "max_toggled.xbm",
    "window-close-symbolic.symbolic.png": "close.xbm",
}
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def parse_xbm(path: Path) -> tuple[int, int, bytes]:
    source = path.read_text(encoding="utf-8")
    width_match = re.search(r"#define\s+\w+_width\s+(\d+)", source)
    height_match = re.search(r"#define\s+\w+_height\s+(\d+)", source)
    bits_match = re.search(r"\{([^}]*)\}", source, re.DOTALL)
    if not width_match or not height_match or not bits_match:
        raise ValueError(f"Invalid XBM control: {path}")

    width = int(width_match.group(1))
    height = int(height_match.group(1))
    data = bytes(
        int(value, 16)
        for value in re.findall(r"0x([0-9a-fA-F]+)", bits_match.group(1))
    )
    expected_size = ((width + 7) // 8) * height
    if len(data) != expected_size:
        raise ValueError(
            f"{path} contains {len(data)} bytes; expected {expected_size}"
        )
    return width, height, data


def png_chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def render_symbolic_png(width: int, height: int, bits: bytes) -> bytes:
    canvas_size = 16
    offset_x = (canvas_size - width) // 2
    offset_y = (canvas_size - height) // 2
    bytes_per_row = (width + 7) // 8
    rows = []

    for canvas_y in range(canvas_size):
        row = bytearray([0])
        for canvas_x in range(canvas_size):
            source_x = canvas_x - offset_x
            source_y = canvas_y - offset_y
            visible = False
            if 0 <= source_x < width and 0 <= source_y < height:
                source_byte = bits[source_y * bytes_per_row + source_x // 8]
                visible = bool(source_byte & (1 << (source_x % 8)))
            row.extend((0, 0, 0, 255 if visible else 0))
        rows.append(bytes(row))

    header = struct.pack(">IIBBBBB", canvas_size, canvas_size, 8, 6, 0, 0, 0)
    return (
        PNG_SIGNATURE
        + png_chunk(b"IHDR", header)
        + png_chunk(b"IDAT", zlib.compress(b"".join(rows), level=9))
        + png_chunk(b"IEND", b"")
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("openbox_theme", type=Path)
    parser.add_argument("overlay_root", type=Path)
    args = parser.parse_args()

    output_dir = args.overlay_root / "icons/16x16/status"
    output_dir.mkdir(parents=True, exist_ok=True)
    for output_name, source_name in CONTROL_SOURCES.items():
        width, height, bits = parse_xbm(args.openbox_theme / source_name)
        (output_dir / output_name).write_bytes(
            render_symbolic_png(width, height, bits)
        )


if __name__ == "__main__":
    main()
