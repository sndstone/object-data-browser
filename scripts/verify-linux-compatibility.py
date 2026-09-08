#!/usr/bin/env python3
"""Reject bundled ELF objects newer than the Mint 20 / Ubuntu 20.04 ABI floor."""
import re
import subprocess
import sys
from pathlib import Path


def check(bundle):
    limit = (2, 31)
    scanned = 0
    highest = (0, 0)
    failures = []
    for path in sorted(bundle.rglob('*')):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        scanned += 1
        result = subprocess.run(['readelf', '--version-info', '--wide', str(path)],
                                check=True, capture_output=True, text=True)
        # Only imported version needs, not versions exported by bundled libraries.
        needs = result.stdout.split('Version needs section', 1)
        if len(needs) < 2:
            continue
        versions = [tuple(map(int, v.split('.'))) for v in
                    re.findall(r'Name: GLIBC_([0-9]+(?:\.[0-9]+)+)', needs[1])]
        if versions:
            maximum = max(versions)
            highest = max(highest, maximum)
            if maximum > limit:
                failures.append(f'{path.relative_to(bundle)}: GLIBC_{".".join(map(str, maximum))}')
    if not scanned:
        raise RuntimeError('No ELF files found in the release bundle.')
    print(f'Scanned {scanned} bundled ELF files; maximum required GLIBC_{".".join(map(str, highest))}.')
    if failures:
        raise RuntimeError('Newer than GLIBC_2.31:\n' + '\n'.join(failures))
    # App and GTK plugins must resolve against the baseline system libraries.
    for path in [bundle / 's3_browser_crossplat', *sorted((bundle / 'lib').glob('*.so'))]:
        result = subprocess.run(['ldd', str(path)], capture_output=True, text=True)
        if result.returncode or 'not found' in result.stdout + result.stderr:
            raise RuntimeError(f'Unresolved runtime dependencies for {path}:\n{result.stdout}{result.stderr}')
    print('App and GTK plugin runtime dependencies resolve on the build baseline.')


if __name__ == '__main__':
    check(Path(sys.argv[1]).resolve())
