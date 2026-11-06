"""Deploy bounded nickname signaling and receiver instructions in the existing sandbox."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import time
import urllib.request

root = Path('/srv/apps/touping')
app = root / 'app'
stage = root / 'ops/staging/release80'
backup = root / 'backups/before80'
files = ['signaling.py', 'Web/receiver.html', 'Web/receiver.js']

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def install(source, target):
    temporary = target.with_name(target.name + '.next80')
    shutil.copyfile(source, temporary)
    os.chmod(temporary, 0o644)
    os.replace(temporary, target)

def verify():
    for route, key, expected in [('health', 'mediaRelay', False), ('baidu/status', 'configured', True)]:
        with urllib.request.urlopen('https://zhibenwang.com/touping/' + route, timeout=15) as response:
            assert json.load(response)[key] == expected
    for name in files[1:]:
        route = '' if name.endswith('.html') else 'receiver.js'
        with urllib.request.urlopen('https://zhibenwang.com/touping/' + route, timeout=15) as response:
            assert hashlib.sha256(response.read()).digest() == hashlib.sha256((stage / name).read_bytes()).digest()
    remote_hash = run('docker', 'exec', 'touping-signaling', 'sha256sum', '/app/signaling.py').split()[0]
    assert remote_hash == hashlib.sha256((stage / 'signaling.py').read_bytes()).hexdigest()

if __name__ == '__main__':
    assert os.geteuid() == 0
    backup.mkdir(mode=0o700)
    for name in files:
        target = backup / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(app / name, target)
    image = json.loads(run('docker', 'inspect', 'touping-signaling'))[0]
    image_id, image_name = image['Image'], image['Config']['Image']
    run('docker', 'tag', image_id, 'touping-signaling:before80')
    compose = ('docker', 'compose', '-p', 'touping', '-f', str(app / 'compose.yml'), '-f', str(root / 'ops/baidu-oauth.override.yml'))
    try:
        for name in files: install(stage / name, app / name)
        run(*compose, 'up', '-d', '--build', '--no-deps', 'signaling')
        for attempt in range(15):
            try:
                verify()
                break
            except Exception:
                if attempt == 14: raise
                time.sleep(1)
        (backup / 'release.json').write_text(json.dumps({'release': 80, 'image_before': image_id, 'result': 'published'}))
        print('PASS release80: source/static hashes match, no relay, OAuth remains configured')
    except Exception:
        for name in files: install(backup / name, app / name)
        run('docker', 'tag', image_id, image_name)
        run(*compose, 'up', '-d', '--no-build', '--no-deps', 'signaling')
        raise
