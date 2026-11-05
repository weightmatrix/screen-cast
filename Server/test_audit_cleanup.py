from pathlib import Path
import os
import tempfile
import unittest
from ops.cleanup_audit import cleanup


class AuditCleanupTests(unittest.TestCase):
    def test_only_expired_regular_closed_segments_are_removed(self):
        with tempfile.TemporaryDirectory() as root:
            audit = Path(root, 'data/audit'); audit.mkdir(parents=True)
            admin = Path(root, 'data/admin-audit'); admin.mkdir()
            now = 2000000000
            for parent, name in [(audit, 'connections.jsonl.199'), (admin, 'access-2020-01-01.jsonl')]:
                path = parent / name; path.write_text('{}\n'); os.utime(path, (1, 1))
            for name in ['connections.jsonl', 'connections.jsonl.1', 'unrelated']:
                (audit / name).write_text('{}\n'); os.utime(audit / name, (now, now))
            self.assertEqual(cleanup(root, now), 2)
            self.assertEqual(len([p for p in audit.iterdir() if p.name != ".lock"]), 3)
            (audit / 'connections.jsonl.2').symlink_to('/etc/passwd')
            with self.assertRaises(ValueError): cleanup(root, now)
