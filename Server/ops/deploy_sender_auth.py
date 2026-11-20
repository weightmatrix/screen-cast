"""Deploy verified sender identity without touching scheduling account data."""
import json
import subprocess
import shutil
import time
from pathlib import Path
ROOT = Path('/srv/apps/touping')
def run(*args): return subprocess.check_output(args, text=True)
def main():
    backup = ROOT/'backups'/('sender-auth-' + time.strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(mode=0o700)
    files = ['signaling.py','account_identity.py','Dockerfile']
    for name in files:
        source = ROOT/'app'/name
        if source.exists(): shutil.copy2(source,backup/name)
    image = json.loads(run('docker','inspect','touping-signaling'))[0]['Image']
    run('docker','tag',image,'touping-signaling:before-sender-auth103')
    for name in files: shutil.copy2(ROOT/'ops/staging'/name,ROOT/'app'/name)
    command = ['docker','compose','-p','touping','-f',str(ROOT/'app/compose.yml'),'-f',str(ROOT/'ops/baidu-oauth.override.yml')]
    try:
        run(*command,'build','signaling')
        run(*command,'up','-d','--no-deps','--no-build','signaling')
        for _ in range(10):
            try:
                run('docker','exec','touping-signaling','python','-c',"import urllib.request; assert urllib.request.urlopen('http://127.0.0.1:8322/health', timeout=3).status==200")
                print('SENDER_AUTH_DEPLOYED'); return
            except subprocess.CalledProcessError: time.sleep(1)
        raise RuntimeError('Health check failed')
    except Exception:
        for name in files:
            old = backup/name
            if old.exists(): shutil.copy2(old,ROOT/'app'/name)
        run('docker','tag','touping-signaling:before-sender-auth103','touping-signaling')
        run(*command,'up','-d','--no-deps','--no-build','signaling')
        raise
if __name__ == '__main__': main()
