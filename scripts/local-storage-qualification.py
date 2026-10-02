#!/usr/bin/env python3
"""Isolated MinIO/Azurite qualification; never loads app profiles or Keychain."""
import base64
import importlib.util
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]

def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def stop(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)

def main():
    children = []
    with tempfile.TemporaryDirectory(prefix='storage-qualification-') as temp:
        folder = Path(temp)
        s3_port, console_port, azure_port = port(), port(), port()
        account, access, secret = 'qualification', secrets.token_hex(12), secrets.token_hex(24)
        azure_key = base64.b64encode(secrets.token_bytes(64)).decode()
        env = dict(os.environ, MINIO_ROOT_USER=access, MINIO_ROOT_PASSWORD=secret,
                   AZURITE_ACCOUNTS=f'{account}:{azure_key}',
                   LOCAL_STORAGE_VERIFY='1', LOCAL_STORAGE_S3_ENDPOINT=f'http://127.0.0.1:{s3_port}',
                   LOCAL_STORAGE_S3_ACCESS=access, LOCAL_STORAGE_S3_SECRET=secret,
                   LOCAL_STORAGE_AZURE_ENDPOINT=f'http://127.0.0.1:{azure_port}/{account}',
                   LOCAL_STORAGE_AZURE_ACCOUNT=account, LOCAL_STORAGE_AZURE_KEY=azure_key)
        try:
            for name, command in [('minio', [str(ROOT / '.tmp/local-s3/bin/minio'), 'server', str(folder / 's3'), '--address', f'127.0.0.1:{s3_port}', '--console-address', f'127.0.0.1:{console_port}']),
                                  ('azurite', [str(ROOT / '.tmp/local-azure/node_modules/.bin/azurite-blob'), '--blobHost', '127.0.0.1', '--blobPort', str(azure_port), '--location', str(folder / 'azure'), '--silent'])]:
                with (folder / f'{name}.log').open('w') as log:
                    children.append(subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True))
            for target in (s3_port, azure_port):
                for _ in range(200):
                    try:
                        with socket.create_connection(('127.0.0.1', target), timeout=.1):
                            break
                    except OSError:
                        if any(p.poll() is not None for p in children):
                            raise RuntimeError('A local emulator exited during startup.')
                        time.sleep(.1)
                else:
                    raise RuntimeError('Local emulator startup timed out.')
            subprocess.run([str(ROOT / '.tmp/toolchains/flutter/bin/flutter'), 'test', 'test/mobile_storage_emulator_test.dart', '--reporter', 'expanded'], cwd=ROOT / 'apps/flutter_app', env=env, check=True)
            from local_storage_workflows import qualify
            qualify(ROOT, folder, env)
            print('Local MinIO/Azurite portable storage qualification passed.', flush=True)
        finally:
            for process in reversed(children):
                stop(process)

if __name__ == '__main__':
    main()
