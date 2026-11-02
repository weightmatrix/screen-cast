"""Private, bounded JSONL metadata. Never pass protocol payloads to this module."""
import datetime, json, os, stat, time, uuid


class AuditUnavailable(Exception):
    pass


class AuditLog:
    def __init__(self, path, max_bytes=5 * 1024 * 1024, backups=39, retention_days=90):
        self.path = os.path.abspath(path)
        self.max_bytes = max_bytes
        self.backups = backups
        self.retention = retention_days * 86400
        self.last_cleanup = 0
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)

    def record(self, event, **metadata):
        try:
            now = time.time()
            if now - self.last_cleanup >= 3600:
                cutoff = now - self.retention
                for index in range(self.backups + 1):
                    path = self.path if index == 0 else f'{self.path}.{index}'
                    if os.path.isfile(path) and os.stat(path).st_mtime < cutoff:
                        os.unlink(path)
                self.last_cleanup = now
            entry = {'version': 1, 'event_id': uuid.uuid4().hex,
                     'time_utc': datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat(),
                     'event': event, **metadata}
            data = (json.dumps(entry, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n').encode()
            if len(data) > 2048:
                raise ValueError('Audit event too large')
            if os.path.exists(self.path) and os.stat(self.path).st_size + len(data) > self.max_bytes:
                for index in range(self.backups, 0, -1):
                    old = self.path if index == 1 else f'{self.path}.{index - 1}'
                    if os.path.exists(old): os.replace(old, f'{self.path}.{index}')
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode): raise ValueError('Audit target is not a file')
                os.fchmod(fd, 0o600)
                remaining = memoryview(data)
                while remaining:
                    count = os.write(fd, remaining)
                    if count <= 0: raise OSError('Short audit write')
                    remaining = remaining[count:]
                os.fsync(fd)
            finally:
                os.close(fd)
        except (OSError, ValueError) as error:
            raise AuditUnavailable('Connection audit unavailable') from error
