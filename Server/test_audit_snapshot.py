import gzip
import hashlib
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
from ops import audit_snapshot as snapshot


class AuditSnapshotTests(unittest.TestCase):
    def packet(self, name='connections.jsonl', body=b'{"event":"example"}\n', digest=None):
        manifest = json.dumps({'version': 1, 'files': [{'name': name, 'size': len(body),
            'sha256': digest or hashlib.sha256(body).hexdigest()}]}).encode()
        return io.BytesIO(gzip.compress(struct.pack('!I', len(manifest)) + manifest + body))

    def test_verified_round_trip_and_two_snapshot_limit(self):
        with tempfile.TemporaryDirectory() as root:
            audit, destination = Path(root, 'audit'), Path(root, 'replica')
            audit.mkdir(); (audit / 'connections.jsonl').write_bytes(b'{"event":"one"}\npartial')
            payload = io.BytesIO(); snapshot.create_snapshot(audit, payload)
            payload.seek(0); snapshot.receive(payload, destination, reserve=0)
            self.assertEqual(next(destination.glob('snapshot-*/connections.jsonl')).read_bytes(), b'{"event":"one"}\n')
            for _ in range(3): snapshot.receive(self.packet(), destination, reserve=0)
            self.assertEqual(len(list(destination.glob('snapshot-*'))), 2)
            self.assertFalse(list(destination.glob('.incoming-*')))
            stale = destination / '.incoming-killed'; stale.mkdir(); (stale / 'partial').write_bytes(b'partial')
            snapshot.receive(self.packet(), destination, reserve=0)
            self.assertFalse(stale.exists())

    def test_rejects_path_traversal_and_hash_mismatch_without_publishing(self):
        with tempfile.TemporaryDirectory() as root:
            for packet in [self.packet('../escape'), self.packet(digest='0' * 64)]:
                with self.assertRaises(ValueError): snapshot.receive(packet, root, reserve=0)
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_rejects_oversized_manifest_and_partial_record(self):
        with tempfile.TemporaryDirectory() as root:
            for packet in [io.BytesIO(gzip.compress(struct.pack('!I', 16385))), self.packet(body=b'partial')]:
                with self.assertRaises(ValueError): snapshot.receive(packet, root, reserve=0)
            self.assertEqual(list(Path(root).iterdir()), [])
