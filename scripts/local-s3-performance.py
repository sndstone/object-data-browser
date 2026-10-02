#!/usr/bin/env python3
"""Run the Flutter app's real storage service against a private local MinIO.

Requires boto3, Flutter, staged desktop engines and a working MinIO binary.
Credentials exist only in child environments; no application state is loaded.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import signal
import socket
import statistics
import subprocess
import tempfile
import threading
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[1]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def cpu_seconds(value):
    days, _, clock = value.rpartition('-')
    total = 0.0
    for part in clock.split(':'):
        total = total * 60 + float(part)
    return total + (int(days) * 86400 if days else 0)


def sample_processes(stop, output):
    """Sample only this runner's descendants; never log unrelated processes."""
    with output.open('w') as stream:
        while not stop.is_set():
            sampled_at = dt.datetime.now(dt.timezone.utc).isoformat()
            result = subprocess.run(
                ['ps', '-axo', 'pid=,ppid=,rss=,time=,comm='],
                text=True, capture_output=True, check=True,
            )
            records = {}
            for line in result.stdout.splitlines():
                parts = line.split(None, 4)
                if len(parts) == 5:
                    pid, parent, rss, cpu, name = parts
                    records[int(pid)] = {
                        'pid': int(pid), 'parentPid': int(parent),
                        'rssKiB': int(rss), 'cpuSeconds': cpu_seconds(cpu),
                        'name': Path(name).name,
                    }
            descendants = {os.getpid()}
            while True:
                expanded = descendants | {
                    pid for pid, item in records.items()
                    if item['parentPid'] in descendants
                }
                if expanded == descendants:
                    break
                descendants = expanded
            stream.write(json.dumps({
                'timestamp': sampled_at,
                'processes': [records[pid] for pid in sorted(descendants)
                              if pid in records and records[pid]['name'] != 'ps'],
            }) + '\n')
            stream.flush()
            stop.wait(0.5)


def stop_process(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=10)


def sha256_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def engine_fingerprints(root, manifest):
    paths = set()
    for engine in manifest['engines']:
        for relative in engine.get('requiredFiles', []):
            path = root / relative
            if path.is_file():
                paths.add(path)
            elif path.is_dir():
                paths.update(path.glob('*.jar'))
    return {str(path.relative_to(root)): sha256_file(path) for path in sorted(paths)}


def summarize(output):
    records = [json.loads(line) for line in
               (output / 'app-service-results.jsonl').read_text().splitlines()]
    if not any(row.get('recordType') == 'run' and row.get('status') == 'completed'
               for row in records):
        raise RuntimeError('No successfully verified application run was recorded.')
    groups = {}
    for row in records:
        if row.get('recordType') == 'measurement' and row.get('status') == 'completed':
            key = (row['engine'], row['case'], row['concurrency'])
            groups.setdefault(key, []).append(row)
    summaries = []
    print('Engine   Workload             Workers   Median ms     Rate', flush=True)
    for (engine, case, concurrency), rows in sorted(groups.items()):
        rate_key = 'wallOpsPerSecond' if case == 'put_64k' else 'miBPerSecond'
        summary = {'engine': engine, 'case': case, 'concurrency': concurrency,
                   'repetitions': len(rows),
                   'medianElapsedMs': statistics.median(row['elapsedMs'] for row in rows)}
        if rate_key in rows[0]:
            rates = [row[rate_key] for row in rows]
            summary.update(rateUnit='ops/s' if rate_key == 'wallOpsPerSecond' else 'MiB/s',
                           medianRate=statistics.median(rates), minRate=min(rates), maxRate=max(rates))
        summaries.append(summary)
        rate = f'{summary["medianRate"]:.1f} {summary["rateUnit"]}' if 'medianRate' in summary else ''
        print(f'{engine:8} {case:20} {concurrency:7} {summary["medianElapsedMs"]:11.1f}  {rate}')
    (output / 'summary.json').write_text(json.dumps(summaries, indent=2) + '\n')
    samples = [json.loads(line) for line in
               (output / 'resources.jsonl').read_text().splitlines()]
    flutter_pids = {p['pid'] for sample in samples for p in sample['processes']
                    if p['name'] == 'flutter_tester'}
    roles = {'minio': 'server', 's3-browser-go-engine': 'go',
             's3-browser-rust-engine': 'rust', 'java': 'java'}
    resources = {}
    for sample in samples:
        for process in sample['processes']:
            role = roles.get(process['name'])
            if process['name'].startswith('python') and process['parentPid'] in flutter_pids:
                role = 'python'
            if role:
                record = resources.setdefault(role, {'sampledPeakRssMiB': 0, 'cpuSecondsByPid': {}})
                record['sampledPeakRssMiB'] = max(record['sampledPeakRssMiB'], process['rssKiB'] / 1024)
                record['cpuSecondsByPid'][str(process['pid'])] = process['cpuSeconds']
    for record in resources.values():
        record['observedCpuSeconds'] = sum(record.pop('cpuSecondsByPid').values())
    (output / 'resource-summary.json').write_text(json.dumps({
        'scope': 'Entire run including warmup, verification and retained benchmark histories; 500ms sampling can miss short peaks.',
        'processes': resources,
    }, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server-binary', type=Path, required=True)
    parser.add_argument('--engine-root', type=Path, required=True)
    parser.add_argument('--flutter', type=Path,
                        default=ROOT / '.tmp/toolchains/flutter/bin/flutter')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--engines', default='python,go,rust,java')
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--transfer-mib', type=int, default=256)
    parser.add_argument('--operations', type=int, default=1024)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 10 or not 8 <= args.transfer_mib <= 1024:
        parser.error('Use 1–10 repetitions and 8–1024 MiB transfers.')
    if not 32 <= args.operations <= 10000:
        parser.error('Use 32–10000 operations.')
    if not set(args.engines.split(',')) <= {'python', 'go', 'rust', 'java'}:
        parser.error('Unknown engine.')
    for path in (args.server_binary, args.flutter, args.engine_root / 'manifest.json'):
        if not path.is_file():
            parser.error(f'Missing dependency: {path}')
    import boto3
    from botocore.config import Config

    output = (args.output or ROOT / '.tmp/performance' /
              dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    version = subprocess.run([str(args.server_binary.resolve()), '--version'],
                             capture_output=True, text=True, check=True).stdout.strip()
    server = flutter = None
    stopped = threading.Event()
    sampler = None
    exit_code = 1
    # This directory owns all server data and recovery state, even after failures.
    with tempfile.TemporaryDirectory(prefix='odb-local-s3-') as temporary:
        work = Path(temporary)
        (work / 'tmp').mkdir()
        (work / 'data').mkdir()
        api_port = free_port()
        endpoint = f'http://127.0.0.1:{api_port}'
        console_port = free_port()
        while console_port == api_port:
            console_port = free_port()
        bucket = 'odb-perf-' + secrets.token_hex(6)
        access, secret = 'local-' + secrets.token_hex(8), secrets.token_hex(24)
        env = dict(os.environ, MINIO_ROOT_USER=access, MINIO_ROOT_PASSWORD=secret,
                   MINIO_BROWSER='off', MINIO_UPDATE='off', TMPDIR=str(work / 'tmp'))
        metadata = {
            'startedAt': dt.datetime.now(dt.timezone.utc).isoformat(),
            'serverVersion': version, 'serverEndpoint': endpoint, 'bucket': bucket,
            'serverSha256': sha256_file(args.server_binary),
            'platform': platform.platform(), 'architecture': platform.machine(),
            'logicalCpus': os.cpu_count(), 'engines': args.engines.split(','),
            'repetitions': args.repetitions, 'transferMiB': args.transfer_mib,
            'operations': args.operations,
            'engineManifest': json.loads((args.engine_root / 'manifest.json').read_text()),
            'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'],
                                               cwd=ROOT, text=True).strip(),
            'workingTreeDirty': bool(subprocess.check_output(
                ['git', 'status', '--porcelain'], cwd=ROOT, text=True)),
            'transport': 'HTTP loopback; server and client on the same host',
        }
        if platform.system() == 'Darwin':
            metadata['processorName'] = subprocess.check_output(
                ['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()
            metadata['memoryBytes'] = int(subprocess.check_output(
                ['sysctl', '-n', 'hw.memsize'], text=True).strip())
        metadata['engineSha256'] = engine_fingerprints(args.engine_root, metadata['engineManifest'])
        (output / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
        try:
            with (output / 'server.log').open('w') as server_log:
                server = subprocess.Popen([
                    str(args.server_binary.resolve()), 'server', str(work / 'data'),
                    '--address', endpoint.removeprefix('http://'),
                    '--console-address', f'127.0.0.1:{console_port}',
                ], env=env, stdout=server_log, stderr=subprocess.STDOUT,
                    start_new_session=True)
            deadline = time.monotonic() + 45
            while True:
                if server.poll() is not None:
                    raise RuntimeError(f'MinIO exited; inspect {output / "server.log"}')
                try:
                    with urllib.request.urlopen(endpoint + '/minio/health/ready', timeout=1) as response:
                        if response.status == 200:
                            break
                except OSError:
                    pass
                if time.monotonic() > deadline:
                    raise RuntimeError('MinIO did not become ready within 45 seconds.')
                time.sleep(0.2)
            client = boto3.client('s3', endpoint_url=endpoint, region_name='us-east-1',
                                  aws_access_key_id=access, aws_secret_access_key=secret,
                                  config=Config(s3={'addressing_style': 'path'}))
            client.create_bucket(Bucket=bucket)
            child_env = dict(os.environ, TMPDIR=str(work / 'tmp'),
                             JAVA_TOOL_OPTIONS=f'-Djava.io.tmpdir={work / "tmp"}',
                             OBJECT_BROWSER_TRANSFER_DIR=str(work / 'transfers'),
                             LOCAL_S3_PERF='1', LOCAL_S3_ENDPOINT=endpoint,
                             LOCAL_S3_ACCESS_KEY=access, LOCAL_S3_SECRET_KEY=secret,
                             LOCAL_S3_BUCKET=bucket,
                             LOCAL_S3_ENGINE_ROOT=str(args.engine_root.resolve()),
                             LOCAL_S3_OUTPUT_DIR=str(output),
                             LOCAL_S3_ENGINES=args.engines,
                             LOCAL_S3_REPETITIONS=str(args.repetitions),
                             LOCAL_S3_TRANSFER_MIB=str(args.transfer_mib),
                             LOCAL_S3_OPERATIONS=str(args.operations))
            sampler = threading.Thread(target=sample_processes,
                                       args=(stopped, output / 'resources.jsonl'), daemon=True)
            sampler.start()
            print(f'Local S3 ready at {endpoint}. Results: {output}', flush=True)
            with (output / 'flutter.log').open('w') as log:
                flutter = subprocess.Popen([
                    str(args.flutter.resolve()), 'test', '--no-pub', '--concurrency=1',
                    '--reporter=expanded', 'test/local_s3_performance_test.dart',
                ], cwd=ROOT / 'apps/flutter_app', env=child_env,
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                exit_code = flutter.wait(timeout=1800)
            # Independently count the real objects before the private server is removed.
            objects = byte_count = 0
            for page in client.get_paginator('list_objects_v2').paginate(Bucket=bucket):
                for item in page.get('Contents', []):
                    objects += 1
                    byte_count += item['Size']
            metadata.update(finalObjectCount=objects, finalObjectBytes=byte_count)
        finally:
            try:
                stop_process(flutter)
            finally:
                try:
                    stop_process(server)
                finally:
                    stopped.set()
                    if sampler:
                        sampler.join(timeout=5)
                    metadata.update(exitCode=exit_code,
                                    finishedAt=dt.datetime.now(dt.timezone.utc).isoformat())
                    (output / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'Flutter exit code: {exit_code}. Local server stopped and data removed.', flush=True)
    if exit_code == 0:
        summarize(output)
    return exit_code


if __name__ == '__main__':
    # Children run in separate process groups. Enter finally even when the
    # launcher is terminated, so those groups and temporary data are cleaned up.
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, terminate)
    raise SystemExit(main())
