#!/usr/bin/env python3
"""Prepare relocatable runtime payloads before platform signing."""
import argparse
import json
import shutil
import subprocess
from pathlib import Path


def python_runtime(source: Path, target: Path):
    # Keep dynamic libraries, certificates, standard library and extensions.
    # Exclude build inputs and package-manager caches during copy, not afterward.
    excluded = {'pkgs', 'include', 'conda-meta', 'compiler_compat', '__pycache__', 'site-packages', '_conda', 'sbin'}
    def ignore(directory, names):
        return [name for name in names if name in excluded or name.endswith(('.a', '.pyc', '.pyo'))]
    shutil.copytree(source, target, dirs_exist_ok=True, symlinks=True, ignore=ignore)


def java_runtime(source: Path, target: Path):
    jlink = source / 'bin' / ('jlink.exe' if __import__('os').name == 'nt' else 'jlink')
    # Keep every Java SE module and dynamic security/charset providers. The
    # explicit set avoids compiler tools while retaining reflective SDK paths.
    modules = {'java.se', 'jdk.unsupported', 'jdk.charsets', 'jdk.localedata', 'jdk.zipfs'}
    modules.update(path.stem for path in (source / 'jmods').glob('*.jmod')
                   if path.stem.startswith(('jdk.crypto.', 'jdk.security.', 'jdk.naming.')))
    subprocess.run([str(jlink), '--module-path', str(source / 'jmods'),
                    '--add-modules', ','.join(sorted(modules)), '--strip-debug', '--no-header-files',
                    '--no-man-pages', '--output', str(target)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('kind', choices=['python', 'java'])
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    args = parser.parse_args()
    if args.kind == 'python':
        python_runtime(args.source, args.target)
    else:
        java_runtime(args.source, args.target)
    files = sorted(str(p.relative_to(args.target)) for p in args.target.rglob('*') if p.is_file())
    (args.target / 'runtime-files.json').write_text(json.dumps(files, indent=2) + '\n')


if __name__ == '__main__':
    main()
