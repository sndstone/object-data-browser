#!/usr/bin/env python3
"""Qualify final runtime payloads without system interpreter fallback."""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('engine_root', type=Path)
    parser.add_argument('--contracts', action='store_true')
    args = parser.parse_args()
    root = args.engine_root.resolve()
    repository = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8-sig'))
    python = root / 'python' / ('python.exe' if os.name == 'nt' else 'bin/python3')
    java = root / 'java/runtime/bin' / ('java.exe' if os.name == 'nt' else 'java')
    if not python.is_file() or not java.is_file():
        raise RuntimeError('Final package must contain its own Python and Java runtimes.')
    env = dict(os.environ)
    env['PYTHONNOUSERSITE'] = '1'
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    env['PYTHONPATH'] = str(root / 'python' / ('Lib/site-packages' if os.name == 'nt' else 'site-packages'))
    env['SSL_CERT_FILE'] = str(root / 'python' / ('Lib/site-packages' if os.name == 'nt' else 'site-packages') / 'certifi/cacert.pem')
    subprocess.run([str(python), '-c', 'import ssl, ctypes, sqlite3, boto3, urllib3, google_crc32c; from azure.identity import DefaultAzureCredential; import cryptography.hazmat.bindings._rust; assert ssl.create_default_context().get_ca_certs()'], env=env, check=True)
    for engine in manifest['engines']:
        working = root / engine.get('workingDirectory', '')
        command = [str(root / engine['executable'])]
        command += [str(working / value) for value in engine.get('arguments', [])]
        request = json.dumps({'requestId': 'payload-health', 'method': 'health', 'params': {}}) + '\n'
        completed = subprocess.run(command, cwd=working, input=request, text=True,
                                   capture_output=True, timeout=30, env=env, check=True)
        messages = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
        if not any(row.get('requestId') == 'payload-health' and row.get('ok') for row in messages):
            raise RuntimeError(f"Packaged {engine['id']} did not pass health: {completed.stderr[-2000:]}")
        print(f"Packaged {engine['id']} health passed", flush=True)
        if args.contracts:
            contract_env = dict(env, ENGINE_CMD_JSON=json.dumps(command), REQUIRE_ENGINE='1')
            subprocess.run([sys.executable, '-m', 'pytest', 'tests/contract', '-q'],
                           cwd=repository, env=contract_env, check=True)


if __name__ == '__main__':
    main()
