"""Atomically publish the receiver state-control assets; no services or credentials are changed."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import urllib.request

root = Path('/srv/apps/touping')
stage = root / 'ops/staging/release92/Web'
web = root / 'app/Web'
backup = root / 'backups/before92-web-publish'
names = ['receiver.html', 'receiver.js', 'receiver-room.js', 'receiver-i18n.js']

def install(source, target):
    temporary = target.with_name(target.name + '.next92')
    shutil.copyfile(source, temporary)
    os.chmod(temporary, 0o644)
    os.replace(temporary, target)

if __name__ == '__main__':
    assert os.geteuid() == 0
    backup.mkdir(mode=0o700)
    for name in names: shutil.copy2(web / name, backup / name)
    try:
        for name in names: install(stage / name, web / name)
        for name in names:
            route = '' if name.endswith('.html') else name
            with urllib.request.urlopen('https://zhibenwang.com/touping/' + route, timeout=15) as response:
                served = response.read()
                # The shared site proxy inserts this existing first-party usage script.
                # Preserve it; do not weaken JS byte checks or strip arbitrary scripts.
                usage = b'<script src="/papers/usage.js" defer></script>'
                if name == 'receiver.html' and served.count(usage) == 1:
                    served = served.replace(usage, b'', 1)
                assert hashlib.sha256(served).digest() == hashlib.sha256((stage / name).read_bytes()).digest(), name
        with urllib.request.urlopen('https://zhibenwang.com/touping/health', timeout=15) as response:
            assert json.load(response)['mediaRelay'] is False
        with urllib.request.urlopen('https://zhibenwang.com/touping/baidu/status', timeout=15) as response:
            assert json.load(response)['configured'] is True
        print('PASS release92 receiver hashes, no relay, OAuth remains configured; no service restart')
    except Exception:
        for name in names: install(backup / name, web / name)
        raise
