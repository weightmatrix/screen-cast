"""Private, bounded JSONL metadata. Never pass protocol payloads to this module."""
import datetime, json, os, stat, time, uuid
import contextlib, fcntl


class AuditUnavailable(Exception):
    pass


class AuditLog:
    def __init__(self, path, max_bytes=5 * 1024 * 1024, backups=199, retention_days=184):
        self.path = os.path.abspath(path)
        self.max_bytes = max_bytes
        self.backups = backups
        self.retention = retention_days * 86400
        self.last_cleanup = 0
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)

    @contextlib.contextmanager
    def exclusive(self):
        fd = os.open(os.path.join(os.path.dirname(self.path), '.lock'), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally: os.close(fd)

    def cleanup(self, now=None):
        with self.exclusive(): self._cleanup(now)

    def _cleanup(self, now=None):
        now = time.time() if now is None else now
        if now - self.last_cleanup < 3600: return
        cutoff = now - self.retention
        for index in range(self.backups + 1):
            path = self.path if index == 0 else f'{self.path}.{index}'
            if os.path.isfile(path) and os.stat(path).st_mtime < cutoff:
                os.unlink(path)
        self.last_cleanup = now

    def record(self, event, **metadata):
        try:
            with self.exclusive(): self._record(event, **metadata)
        except (OSError, ValueError) as error:
            raise AuditUnavailable('Connection audit unavailable') from error

    def _record(self, event, **metadata):
        try:
            now = time.time()
            self._cleanup(now)
            entry = {'version': 1, 'event_id': uuid.uuid4().hex,
                     'time_utc': datetime.datetime.fromtimestamp(now, datetime.timezone.utc).isoformat(),
                     'event': event, **metadata}
            data = (json.dumps(entry, ensure_ascii=True, separators=(',', ':'), allow_nan=False) + '\n').encode()
            if len(data) > 2048:
                raise ValueError('Audit event too large')
            # Close a segment at least daily, bounding expiry overshoot to one day.
            rotate = os.path.exists(self.path) and (os.stat(self.path).st_size + len(data) > self.max_bytes or
                datetime.datetime.fromtimestamp(os.stat(self.path).st_mtime, datetime.timezone.utc).date() !=
                datetime.datetime.fromtimestamp(now, datetime.timezone.utc).date())
            if rotate:
                oldest = f'{self.path}.{self.backups}'
                if os.path.exists(oldest):
                    # Never evict unexpired records merely to keep accepting new connections.
                    raise AuditUnavailable('Audit capacity exhausted; increase storage before admitting connections')
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
