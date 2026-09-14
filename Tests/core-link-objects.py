#!/usr/bin/env python3
"""List current NoodleCore and dependency objects for standalone Swift fixtures.

Run after `swift build --target NoodleCore`. SwiftPM can leave object files for
deleted sources behind, so directory globs can link retired code into a fixture.
Use its generated output maps, and keep the shared dependency list here.
"""

import json
from pathlib import Path
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: core-link-objects.py SWIFTPM_BIN_PATH")
    directory = Path(sys.argv[1])
    objects = set()
    for module in ("NoodleCore", "NoodleWallpaperCore", "ComputerBridge", "AppletBridge"):
        mapping = json.loads((directory / f"{module}.build/output-file-map.json").read_text())
        for outputs in mapping.values():
            if name := outputs.get("object"):
                path = Path(name)
                if not path.is_file():
                    raise SystemExit(f"Missing build object: {path}. Build NoodleCore first.")
                objects.add(str(path))
    print("\n".join(sorted(objects)))


if __name__ == "__main__":
    main()
