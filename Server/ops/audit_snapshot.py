"""Bounded private audit snapshots over a forced-command SSH account. No dependencies."""
import argparse
import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time

MAX_FILE = 5 * 1024 * 1024
MAX_TOTAL = 40 * MAX_FILE
NAME = re.compile(r'connections\.jsonl(?:\.([1-9]|[12][0-9]|3[0-9]))?')


def exact(stream, count):
    data = bytearray()
    while len(data) < count:
        part = stream.read(min(65536, count - len(data)))
        if not part: raise ValueError('Incomplete snapshot')
        data.extend(part)
    return bytes(data)


def receive(stream, destination, reserve=1024 * 1024 * 1024):
    destination = Path(destination)
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    # The caller holds the process lock. Recover from a killed prior transfer.
    for leftover in destination.glob('.incoming-*'):
        if leftover.is_dir() and not leftover.is_symlink(): shutil.rmtree(leftover)
    for old in sorted(destination.glob('snapshot-*'), reverse=True)[2:]:
        if old.is_dir() and not old.is_symlink(): shutil.rmtree(old)
    with tempfile.TemporaryDirectory(prefix='.incoming-', dir=destination) as stage:
        with gzip.GzipFile(fileobj=stream, mode='rb') as source:
            length = struct.unpack('!I', exact(source, 4))[0]
            if length > 16384: raise ValueError('Manifest too large')
            manifest = json.loads(exact(source, length))
            files = manifest.get('files')
            if manifest.get('version') != 1 or not isinstance(files, list) or not 1 <= len(files) <= 40: raise ValueError('Invalid manifest')
            total = 0
            names = set()
            for entry in files:
                name, size, digest = entry['name'], entry['size'], entry['sha256']
                if not isinstance(name, str) or not NAME.fullmatch(name) or name in names: raise ValueError('Invalid filename')
                if type(size) is not int or not 0 <= size <= MAX_FILE: raise ValueError('Invalid file size')
                if not isinstance(digest, str) or not re.fullmatch('[a-f0-9]{64}', digest): raise ValueError('Invalid hash')
                names.add(name); total += size
            if total > MAX_TOTAL or shutil.disk_usage(destination).free < total + reserve: raise ValueError('Insufficient snapshot budget')
            for entry in files:
                content = exact(source, entry['size'])
                if hashlib.sha256(content).hexdigest() != entry['sha256']: raise ValueError('Snapshot hash mismatch')
                if content and not content.endswith(b'\n'): raise ValueError('Partial audit record')
                target = Path(stage, entry['name'])
                with target.open('xb') as output:
                    os.chmod(target, 0o600); output.write(content); output.flush(); os.fsync(output.fileno())
            if source.read(1): raise ValueError('Trailing snapshot data')
        manifest['received_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with Path(stage, 'manifest.json').open('w') as output:
            os.chmod(output.name, 0o600); json.dump(manifest, output); output.flush(); os.fsync(output.fileno())
        fd = os.open(stage, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
        snapshot = destination / ('snapshot-' + f'{time.time_ns():020d}')
        os.rename(stage, snapshot)
        for old in sorted(destination.glob('snapshot-*'), reverse=True)[2:]:
            if old.is_dir() and not old.is_symlink(): shutil.rmtree(old)
        # Rename + removal durability, in addition to fsynced audit files.
        fd = os.open(destination, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    return manifest


def create_snapshot(audit, output):
    files, bodies = [], []
    for path in sorted(Path(audit).iterdir()):
        if not NAME.fullmatch(path.name): continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError: continue  # Rotation between directory listing and open.
        with os.fdopen(fd, 'rb') as stream: body = stream.read(MAX_FILE + 1)
        if len(body) > MAX_FILE: raise ValueError('Source exceeds audit budget')
        # A concurrently appended final record is retried on the next snapshot.
        body = body[:body.rfind(b'\n') + 1]
        files.append({'name': path.name, 'size': len(body), 'sha256': hashlib.sha256(body).hexdigest()})
        bodies.append(body)
    if not files: raise ValueError('No audit files')
    manifest = json.dumps({'version': 1, 'files': files}, separators=(',', ':')).encode()
    with gzip.GzipFile(fileobj=output, mode='wb', mtime=0) as target:
        target.write(struct.pack('!I', len(manifest))); target.write(manifest)
        for body in bodies: target.write(body)
    return hashlib.sha256(manifest).hexdigest()


def send(root):
    root = Path(root)
    config = json.loads((root / 'secrets/replication.json').read_text())
    state = root / 'data/replication'
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt = state / 'last-success.json'
    with tempfile.TemporaryFile(dir=state) as payload:
        fingerprint = create_snapshot(root / 'data/audit', payload)
        if receipt.exists() and json.loads(receipt.read_text()).get('fingerprint') == fingerprint:
            print('Audit unchanged; last verified snapshot retained'); return
        payload.seek(0)
        result = subprocess.run(['ssh', '-i', str(root / 'secrets/replica_ed25519'),
            '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
            '-o', 'UserKnownHostsFile=' + str(root / 'secrets/known_hosts'),
            config['destination'], 'audit-snapshot-v1'], stdin=payload, capture_output=True, timeout=1100)
        if result.returncode != 0 or result.stdout.strip() != b'AUDIT_SNAPSHOT_OK': raise RuntimeError('Remote audit snapshot failed')
    status = {'fingerprint': fingerprint, 'verified_utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    temporary = receipt.with_suffix('.tmp')
    temporary.write_text(json.dumps(status)); os.chmod(temporary, 0o600); os.replace(temporary, receipt)
    print('Audit snapshot verified on backup server')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['send', 'receive'])
    parser.add_argument('--root', default='/srv/apps/touping')
    args = parser.parse_args()
    if args.mode == 'receive':
        if os.environ.get('SSH_ORIGINAL_COMMAND') != 'audit-snapshot-v1': raise ValueError('Only audit snapshots allowed')
        destination = Path(args.root) / 'data/replica'
        with (destination / '.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            receive(sys.stdin.buffer, destination)
            print('AUDIT_SNAPSHOT_OK')
    else: send(args.root)


if __name__ == '__main__':
    try: main()
    except Exception as error:
        print('Audit replication failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
