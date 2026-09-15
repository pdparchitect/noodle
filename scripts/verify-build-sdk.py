#!/usr/bin/env python3
"""Reject executables whose linked SDK would select the wrong macOS behavior."""
import re
import subprocess
import sys


def version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def verify(output, expected):
    sdks = re.findall(r'^\s*sdk\s+(\d+(?:\.\d+){0,2})\s*$', output, re.MULTILINE)
    if not sdks:
        raise ValueError('The executable has no linked SDK version.')
    if any(version(sdk) != version(expected) for sdk in sdks):
        raise ValueError(f'Linked SDK {", ".join(sdks)} does not match build SDK {expected}.')


def main():
    if len(sys.argv) != 3:
        print('Usage: verify-build-sdk.py EXECUTABLE SDK_VERSION', file=sys.stderr)
        return 2
    executable, expected = sys.argv[1:]
    try:
        output = subprocess.check_output(['xcrun', 'vtool', '-show-build', executable], text=True)
        verify(output, expected)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'{executable}: {error} Rebuild with the matching Xcode build engine.', file=sys.stderr)
        return 1
    print(f'Verified linked SDK {expected}: {executable}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
