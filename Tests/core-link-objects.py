#!/usr/bin/env python3
"""List current NoodleCore and dependency objects for standalone Swift fixtures.

Run after `swift build --target NoodleCore`, or after building the extra modules named
after the bin path, such as NoodleRuntimeSettings with its own dependencies. SwiftPM can leave object files for
deleted sources behind, so directory globs can link retired code into a fixture.
Use its generated output maps, and keep the shared dependency list here.
"""

import json
from pathlib import Path
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit("Usage: core-link-objects.py SWIFTPM_BIN_PATH [MODULE ...]")
    directory = Path(sys.argv[1])
    objects = set()
    for module in ("NoodleCore", "NoodleWallpaperCore", "ComputerBridge", "AppletBridge", "BrowserBridge", *sys.argv[2:]):
        mapping = json.loads((directory / f"{module}.build/output-file-map.json").read_text())
        for outputs in mapping.values():
            if name := outputs.get("object"):
                path = Path(name)
                if not path.is_file():
                    raise SystemExit(f"Missing build object: {path}. Build {module} first.")
                objects.add(str(path))
    print("\n".join(sorted(objects)))


if __name__ == "__main__":
    main()
