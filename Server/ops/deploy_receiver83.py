"""Atomically publish the two receiver assets; no services or credentials are changed."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import urllib.request

root = Path('/srv/apps/touping')
stage = root / 'ops/staging/release83/Web'
web = root / 'app/Web'
backup = root / 'backups/before83-web'
names = ['receiver.html', 'receiver.js']

def install(source, target):
    temporary = target.with_name(target.name + '.next83')
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
                assert hashlib.sha256(response.read()).digest() == hashlib.sha256((stage / name).read_bytes()).digest()
        with urllib.request.urlopen('https://zhibenwang.com/touping/health', timeout=15) as response:
            assert json.load(response)['mediaRelay'] is False
        with urllib.request.urlopen('https://zhibenwang.com/touping/baidu/status', timeout=15) as response:
            assert json.load(response)['configured'] is True
        print('PASS release83 receiver hashes, no relay, OAuth remains configured; no service restart')
    except Exception:
        for name in names: install(backup / name, web / name)
        raise
