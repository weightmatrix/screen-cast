"""Expire closed metadata segments even when pairing/admin services are idle."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import stat
import time

PATTERNS = {'audit': re.compile(r'connections\.jsonl(?:\.([1-9]|[1-9][0-9]|1[0-9]{2}))?'),
            'admin-audit': re.compile(r'access-\d{4}-\d{2}-\d{2}\.jsonl')}


def cleanup(root, now=None):
    cutoff = (time.time() if now is None else now) - 184 * 86400
    removed = 0
    for directory, pattern in PATTERNS.items():
        parent = Path(root) / 'data' / directory
        if not parent.exists(): continue
        if parent.is_symlink(): raise ValueError('Audit directories must not be symbolic links')
        fd = os.open(parent / '.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            owner = parent.stat()
            os.fchown(fd, owner.st_uid, owner.st_gid)
            fcntl.flock(fd, fcntl.LOCK_EX)
            for path in parent.iterdir():
                if not pattern.fullmatch(path.name): continue
                info = path.stat(follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode): raise ValueError('Audit segment must be a regular file')
                if info.st_mtime < cutoff:
                    path.unlink(); removed += 1
        finally: os.close(fd)
    return removed


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', default='/srv/apps/touping')
    args = parser.parse_args()
    print('Expired metadata segments removed:', cleanup(args.root))
